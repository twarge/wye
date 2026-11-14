import Foundation
import GitKit
import Synchronization
import Testing
@testable import WyeUI

/// A clock the tests move.
private final class TestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_700_000_000))

    var now: Date { date.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// A transport that answers every request with no pull requests after a
/// moment, and counts how many were under way at once.
private final class SlowTransport: HTTPTransport {
    private let state = Mutex<(current: Int, peak: Int, total: Int)>((0, 0, 0))

    var peak: Int { state.withLock { $0.peak } }
    var total: Int { state.withLock { $0.total } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withLock {
            $0.current += 1
            $0.total += 1
            $0.peak = max($0.peak, $0.current)
        }
        try? await Task.sleep(for: .milliseconds(20))
        state.withLock { $0.current -= 1 }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badURL)
        }
        return (Data(ReviewRequestsTests.searchJSON(nodes: "").utf8), response)
    }
}

/// A transport that fails as an offline device does, and counts the attempts.
private final class CountingOfflineTransport: HTTPTransport {
    private let count = Mutex(0)

    var attempts: Int { count.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count.withLock { $0 += 1 }
        throw URLError(.notConnectedToInternet)
    }
}

/// The Review's pull requests to review: asked of recorded responses, with
/// accounts kept in memory, so nothing here reaches a service or the Keychain.
@MainActor
@Suite struct ReviewRequestsTests {
    let stub = StubTransport()
    let accounts = AccountStore(secrets: MemorySecretStore(), preferences: MemoryAccountPreferences())
    private let clock = TestClock()

    /// GitHub's answer to a search for pull requests.
    nonisolated static func searchJSON(nodes: String, next: String? = nil) -> String {
        let cursor = next.map { "\"\($0)\"" } ?? "null"
        return """
        {"data":{"search":{"pageInfo":{"hasNextPage":\(next != nil),"endCursor":\(cursor)},"nodes":[\(nodes)]}}}
        """
    }

    private func requests(transport: (any HTTPTransport)? = nil, concurrentRequests: Int = 4) -> ReviewRequests {
        let clock = clock
        return ReviewRequests(
            accounts: accounts, transport: transport ?? stub, concurrentRequests: concurrentRequests, now: { clock.now }
        )
    }

    @discardableResult
    private func signIn(
        _ kind: HostingKind = .github, host: String? = nil, login: String = "octo", signIn: HostingAccount.SignIn = .token
    ) throws -> HostingAccount {
        let account = HostingAccount(kind: kind, host: host ?? kind.defaultHost, login: login, signIn: signIn)
        try accounts.save(account, secret: HostingSecret(token: "tok"))
        return account
    }

    private func remote(_ name: String = "origin", _ url: String = "https://github.com/octo/project.git") -> Remote {
        Remote(name: name, url: url, branches: [])
    }

    /// The repository each GitHub search was for.
    private var searched: [String] {
        stub.requests.compactMap { request in
            let variables = request.jsonBody?["variables"] as? [String: Any]
            return (variables?["q"] as? String)?.split(separator: " ").first.map(String.init)
        }
    }

    // MARK: Asking

    @Test func asksTheRemotesServiceForPullRequestsToReview() async throws {
        try signIn()
        stub.on("POST", "/graphql", json: Self.searchJSON(nodes: GitHubServiceTests.graphPullRequest))
        let answer = await requests().reviewRequests(for: [remote()])
        #expect(answer == ReviewRequests.Answer(requests: [
            ReviewRequest(
                repository: "github.com/octo/project", kind: .github, number: 12, title: "Add login", author: "mona",
                isDraft: true, updatedAt: ISO8601DateFormatter().date(from: "2024-05-03T10:00:00Z"),
                webURL: URL(string: "https://github.com/octo/project/pull/12")
            )
        ]))
        let request = try #require(stub.last("POST", "/graphql"))
        #expect(request.url?.host() == "api.github.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let variables = try #require(request.jsonBody?["variables"] as? [String: Any])
        #expect(variables["q"] as? String == "repo:octo/project is:pr is:open review-requested:@me sort:updated-desc")
    }

    @Test func asksGitLabForMergeRequests() async throws {
        try signIn(.gitlab, login: "mona")
        stub.on("GET", "/merge_requests?", json: "[\(GitLabServiceTests.mergeRequestJSON)]")
        let answer = await requests().reviewRequests(for: [remote("origin", "git@gitlab.com:group/sub/project.git")])
        let request = try #require(answer.requests.first)
        #expect(request.kind == .gitlab)
        #expect(request.reference == "!7")
        #expect(request.repository == "gitlab.com/group/sub/project")
        let sent = try #require(stub.last("GET", "/merge_requests?"))
        #expect(sent.query("reviewer_username") == "mona")
        #expect(sent.query("state") == "opened")
        let review = RepositoryReview(
            id: UUID(), name: "project", branch: "main", upstream: "origin/main", hasRemote: true, entries: [],
            commits: [], ahead: 0, behind: 0, reviewRequests: answer.requests
        )
        #expect(review.needsAttention)
        #expect(review.summary == "1 merge request to review")
    }

    @Test func readsOnPastAPageWithNoneToReview() async throws {
        try signIn(.gitea)
        let others = (1...30).map { GiteaServiceTests.pullJSON(number: $0) }.joined(separator: ",")
        let asked = GiteaServiceTests.pullJSON(number: 31, title: "Fix it", reviewers: #"[{"login":"octo"}]"#)
        stub.on("GET", "page=2", json: "[\(asked)]")
        stub.on("GET", "/repos/owner/project/pulls", json: "[\(others)]")
        let answer = await requests().reviewRequests(for: [remote("origin", "https://codeberg.org/owner/project.git")])
        #expect(answer.requests.map(\.number) == [31])
        #expect(answer.requests.first?.title == "Fix it")
        #expect(!answer.hasMore)
        #expect(stub.requests.count == 2)
    }

    @Test func stopsAfterAFewPagesAndSaysThereAreMore() async throws {
        try signIn(.gitea)
        let full = (1...30).map { GiteaServiceTests.pullJSON(number: $0, reviewers: #"[{"login":"octo"}]"#) }
            .joined(separator: ",")
        stub.on("GET", "/repos/owner/project/pulls", json: "[\(full)]")
        let answer = await requests().reviewRequests(for: [remote("origin", "https://codeberg.org/owner/project.git")])
        #expect(stub.requests.count == ReviewRequests.pageLimit)
        // The same thirty each time, counted once.
        #expect(answer.requests.count == 30)
        #expect(answer.hasMore)
    }

    @Test func asksUpstreamAndOriginAndNoOtherRemote() async throws {
        try signIn()
        stub.on("POST", "/graphql", json: Self.searchJSON(nodes: GitHubServiceTests.graphPullRequest))
        let remotes = [
            remote("mona", "https://github.com/mona/project.git"), remote("origin", "git@github.com:octo/project.git"),
            remote("upstream", "https://github.com/team/project.git")
        ]
        let answer = await requests().reviewRequests(for: remotes)
        #expect(searched == ["repo:team/project", "repo:octo/project"])
        #expect(answer.requests.map(\.id) == ["github.com/team/project#12", "github.com/octo/project#12"])
    }

    @Test func asksTheFirstHostedRemoteWhereNoneIsOrigin() async throws {
        try signIn()
        stub.on("POST", "/graphql", json: Self.searchJSON(nodes: ""))
        let remotes = [remote("backup", "/Volumes/Backup/project.git"), remote("github", "https://github.com/octo/project")]
        #expect(await requests().reviewRequests(for: remotes) == .none)
        #expect(searched == ["repo:octo/project"])
    }

    // MARK: Keeping

    @Test func keepsAnAnswerForAWhile() async throws {
        try signIn()
        stub.on("POST", "/graphql", json: Self.searchJSON(nodes: GitHubServiceTests.graphPullRequest))
        let requests = requests()
        let first = await requests.reviewRequests(for: [remote()])
        clock.advance(ReviewRequests.lifetime - 1)
        #expect(await requests.reviewRequests(for: [remote()]) == first)
        #expect(stub.requests.count == 1)
        clock.advance(2)
        #expect(await requests.reviewRequests(for: [remote()]) == first)
        #expect(stub.requests.count == 2)
    }

    @Test func asksAgainSoonerWhenTold() async throws {
        try signIn()
        stub.on("POST", "/graphql", json: Self.searchJSON(nodes: ""))
        let requests = requests()
        _ = await requests.reviewRequests(for: [remote()])
        clock.advance(5)
        // Not for each of several refreshes in a row.
        _ = await requests.reviewRequests(for: [remote()], asksAgain: true)
        #expect(stub.requests.count == 1)
        clock.advance(ReviewRequests.lifetimeWhenAskedAgain)
        _ = await requests.reviewRequests(for: [remote()], asksAgain: true)
        #expect(stub.requests.count == 2)
    }

    @Test func foldersOfOneRepositoryShareOneRequest() async throws {
        try signIn()
        let slow = SlowTransport()
        let requests = requests(transport: slow)
        async let https = requests.reviewRequests(for: [remote()])
        async let ssh = requests.reviewRequests(for: [remote("origin", "git@github.com:octo/project.git")])
        _ = await (https, ssh)
        #expect(slow.total == 1)
    }

    @Test func asksAFewAtATime() async throws {
        try signIn()
        let slow = SlowTransport()
        let requests = requests(transport: slow, concurrentRequests: 3)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                let folder = remote("origin", "https://github.com/octo/project-\(index).git")
                group.addTask { _ = await requests.reviewRequests(for: [folder]) }
            }
        }
        #expect(slow.total == 12)
        #expect(slow.peak <= 3)
        #expect(slow.peak > 1)
    }

    // MARK: Staying quiet

    @Test func asksNothingWithoutAnAccountThatCanAsk() async throws {
        // A token a remote's prompt was answered with was never checked against the service.
        try signIn(.gitlab, signIn: .gitPrompt)
        let requests = requests()
        #expect(await requests.reviewRequests(for: [remote()]) == .none)
        #expect(await requests.reviewRequests(for: [remote("origin", "https://gitlab.com/group/project.git")]) == .none)
        #expect(await requests.reviewRequests(for: [remote("origin", "https://git.example.com/team/app.git")]) == .none)
        #expect(await requests.reviewRequests(for: [remote("origin", "/Users/someone/project.git")]) == .none)
        #expect(await requests.reviewRequests(for: [Remote(name: "origin", url: nil, branches: [])]) == .none)
        #expect(await requests.reviewRequests(for: []) == .none)
        #expect(stub.requests.isEmpty)
    }

    @Test func leavesARefusedAccountAloneUntilTheAccountsChange() async throws {
        try signIn()
        stub.on("POST", "/graphql", status: 401, json: #"{"message":"Bad credentials"}"#)
        let requests = requests()
        requests.accountsChanged(to: 1)
        #expect(await requests.reviewRequests(for: [remote()]) == .none)
        // Another repository of the same account would only be refused too.
        #expect(await requests.reviewRequests(for: [remote("origin", "https://github.com/octo/other.git")]) == .none)
        #expect(stub.requests.count == 1)
        // Reading the Review again without anything changed asks nothing.
        requests.accountsChanged(to: 1)
        _ = await requests.reviewRequests(for: [remote()], asksAgain: true)
        #expect(stub.requests.count == 1)
        // Signed in again: asked at once.
        requests.accountsChanged(to: 2)
        _ = await requests.reviewRequests(for: [remote()])
        #expect(stub.requests.count == 2)
    }

    @Test func waitsOutALimitOnRequests() async throws {
        try signIn()
        let reset = clock.now.addingTimeInterval(20 * 60)
        stub.on(
            "POST", "/graphql", status: 403, json: #"{"message":"API rate limit exceeded"}"#,
            headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))],
            once: true
        )
        stub.on("POST", "/graphql", json: Self.searchJSON(nodes: GitHubServiceTests.graphPullRequest))
        let requests = requests()
        #expect(await requests.reviewRequests(for: [remote()]) == .none)
        clock.advance(19 * 60)
        #expect(await requests.reviewRequests(for: [remote()]) == .none)
        #expect(stub.requests.count == 1)
        clock.advance(61)
        #expect(await requests.reviewRequests(for: [remote()]).requests.map(\.number) == [12])
        #expect(stub.requests.count == 2)
    }

    @Test func saysNothingOffline() async throws {
        try signIn()
        let offline = CountingOfflineTransport()
        let requests = requests(transport: offline)
        #expect(await requests.reviewRequests(for: [remote()]) == .none)
        #expect(await requests.reviewRequests(for: [remote("origin", "https://github.com/octo/other.git")]) == .none)
        #expect(offline.attempts == 1)
        // The network may be back before long.
        clock.advance(31)
        _ = await requests.reviewRequests(for: [remote()])
        #expect(offline.attempts == 2)
    }

    @Test func keepsWhatWasHeardWhenAskingLaterFails() async throws {
        try signIn()
        stub.on("POST", "/graphql", json: Self.searchJSON(nodes: GitHubServiceTests.graphPullRequest), once: true)
        stub.on("POST", "/graphql", status: 502, json: #"{"message":"Bad gateway"}"#)
        let requests = requests()
        let heard = await requests.reviewRequests(for: [remote()])
        #expect(heard.requests.count == 1)
        clock.advance(ReviewRequests.lifetime + 1)
        #expect(await requests.reviewRequests(for: [remote()]) == heard)
        #expect(stub.requests.count == 2)
        // A repository whose service failed is left alone for a couple of minutes; another is still asked.
        _ = await requests.reviewRequests(for: [remote()])
        _ = await requests.reviewRequests(for: [remote("origin", "https://github.com/octo/other.git")])
        #expect(searched == ["repo:octo/project", "repo:octo/project", "repo:octo/other"])
    }

    @Test func aRepositoryTheAccountCannotSeeIsItsOwnFailure() async throws {
        try signIn(.gitlab, login: "mona")
        stub.on("GET", "/projects/group%2Fsecret/merge_requests", status: 404, json: #"{"message":"404 Project Not Found"}"#)
        stub.on("GET", "/merge_requests?", json: "[\(GitLabServiceTests.mergeRequestJSON)]")
        let requests = requests()
        #expect(await requests.reviewRequests(for: [remote("origin", "https://gitlab.com/group/secret.git")]) == .none)
        let seen = await requests.reviewRequests(for: [remote("origin", "https://gitlab.com/group/sub/project.git")])
        #expect(seen.requests.map(\.number) == [7])
    }
}

/// The Review's reading of a repository in its folder, and its model's
/// putting that together with what a service says.
@MainActor
@Suite struct ReviewReadingTests {
    /// A clone of a repository on this disk, whose first branch follows the
    /// other's and whose `topic` follows the other's `topic`.
    private struct Scratch {
        let folder: URL
        let origin: Repository
        let work: Repository
        /// The branch a new repository starts on here, `main` or `master`,
        /// by full reference name.
        let main: String
        let identity = GitIdentity(name: "Test Author", email: "author@example.com")

        /// The first branch as people write it.
        var mainName: String { String(main.dropFirst("refs/heads/".count)) }

        var workURL: URL { folder.appending(path: "Documents/work", directoryHint: .isDirectory) }
        var originURL: URL { folder.appending(path: "origin", directoryHint: .isDirectory) }

        init() async throws {
            folder = FileManager.default.temporaryDirectory
                .appending(path: "WyeUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
            let originURL = folder.appending(path: "origin", directoryHint: .isDirectory)
            let workURL = folder.appending(path: "Documents/work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: workURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            origin = try Repository.create(at: originURL)
            try await origin.setLocalIdentity(identity)
            try Data("one\n".utf8).write(to: originURL.appending(path: "a.txt"))
            try await origin.stage(["a.txt"])
            _ = try await origin.commit(message: "One", as: identity)
            main = try await origin.head().branchName ?? "refs/heads/main"
            try await origin.createBranch(named: "topic")
            work = try await Repository.clone(from: originURL.path(percentEncoded: false), to: workURL)
            try await work.setLocalIdentity(identity)
            let topic = try await work.createBranch(named: "topic")
            try await work.setUpstream(of: topic, to: "refs/remotes/origin/topic")
        }

        /// Commits a change to a file on whichever branch is checked out.
        func commit(_ message: String, in repository: Repository, at url: URL) async throws {
            try Data((message + "\n").utf8).write(to: url.appending(path: message + ".txt"))
            try await repository.stage([message + ".txt"])
            _ = try await repository.commit(message: message, as: identity)
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func aCloneLevelWithItsRemoteNeedsNoAttention() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let read = try await ReviewModel.read(at: scratch.workURL, id: UUID(), name: "work")
        #expect(read.review.branch == scratch.mainName)
        #expect(read.review.upstream == "origin/" + scratch.mainName)
        #expect(read.review.otherBranches.isEmpty)
        #expect(!read.review.needsAttention)
        #expect(read.remotes.map(\.name) == ["origin"])
    }

    @Test func readsCommitsToPullAsOfTheLastFetch() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        try await scratch.commit("Two", in: scratch.origin, at: scratch.originURL)
        try await scratch.commit("Three", in: scratch.origin, at: scratch.originURL)
        // Not known of until fetched: the Review does not fetch.
        #expect(try await !ReviewModel.read(at: scratch.workURL, id: UUID(), name: "work").review.needsAttention)
        try await scratch.work.fetch(remote: "origin")
        let review = try await ReviewModel.read(at: scratch.workURL, id: UUID(), name: "work").review
        #expect(review.behind == 2)
        #expect(!review.hasWork)
        #expect(review.needsAttention)
        #expect(review.summary == "2 commits to pull")
    }

    @Test func readsAnotherBranchWhoseUpstreamIsAheadButNotOneWithUnpushedCommits() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        // A commit on `topic` here that the remote lacks is not a reason to list the repository…
        try await scratch.work.checkOut(branch: "refs/heads/topic")
        try await scratch.commit("Local", in: scratch.work, at: scratch.workURL)
        try await scratch.work.checkOut(branch: scratch.main)
        var review = try await ReviewModel.read(at: scratch.workURL, id: UUID(), name: "work").review
        #expect(review.otherBranches.isEmpty)
        #expect(!review.needsAttention)
        // …and one on the remote's `topic` that it lacks is.
        try await scratch.origin.checkOut(branch: "refs/heads/topic")
        try await scratch.commit("Remote", in: scratch.origin, at: scratch.originURL)
        try await scratch.work.fetch(remote: "origin")
        review = try await ReviewModel.read(at: scratch.workURL, id: UUID(), name: "work").review
        #expect(review.otherBranches == [BranchToPull(name: "topic", upstream: "origin/topic", behind: 1)])
        #expect(review.behind == 0)
        #expect(!review.hasWork)
        #expect(review.needsAttention)
        #expect(review.summary == "1 commit to pull on topic")
    }

    @Test func listsARepositoryOnlyForAPullRequestToReview() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        // As a clone from a service: the address alone says where to ask.
        try await scratch.work.setURL("https://github.com/octo/project.git", ofRemote: "origin")
        let library = RepositoryLibrary(
            storage: scratch.folder.appending(path: "Repositories.json"),
            documents: scratch.folder.appending(path: "Documents"), filesStorage: nil
        )
        #expect(library.listedBookmarks.map(\.name) == ["work"])
        let accounts = AccountStore(secrets: MemorySecretStore(), preferences: MemoryAccountPreferences())
        try accounts.save(
            HostingAccount(kind: .github, host: "github.com", login: "octo", signIn: .token), secret: HostingSecret(token: "tok")
        )
        let stub = StubTransport()
        stub.on("POST", "/graphql", json: ReviewRequestsTests.searchJSON(nodes: ""), once: true)
        stub.on("POST", "/graphql", json: ReviewRequestsTests.searchJSON(nodes: GitHubServiceTests.graphPullRequest))
        let clock = TestClock()
        let requests = ReviewRequests(accounts: accounts, transport: stub, now: { clock.now })
        // The checks of its branches are another test's: here no account reads them.
        let noAccounts = AccountStore(secrets: MemorySecretStore(), preferences: MemoryAccountPreferences())
        let model = ReviewModel(
            requests: requests, checks: ReviewChecks(accounts: noAccounts, transport: stub, gate: requests.gate)
        )

        // Nobody asks for a review: committed, pushed and level, it stays out.
        await model.load(library.listedBookmarks, from: library)
        #expect(model.reviews.count == 1)
        #expect(model.needingAttention.isEmpty)
        #expect(stub.requests.count == 1)

        // Somebody does, once the answer has aged.
        clock.advance(ReviewRequests.lifetime + 1)
        await model.load(library.listedBookmarks, from: library)
        let listed = try #require(model.needingAttention.first)
        #expect(listed.name == "work")
        #expect(!listed.hasWork)
        #expect(listed.reviewRequests.map(\.reference) == ["#12"])
        #expect(listed.summary == "1 pull request to review")
        #expect(ReviewTotals(model.needingAttention).sentence == "1 pull request to review in 1 repository")

        // Read again, it is listed from the start with what was last heard.
        await model.load(library.listedBookmarks, from: library)
        #expect(model.needingAttention.first?.reviewRequests.count == 1)
        #expect(stub.requests.count == 2)
    }

    // MARK: Checks

    @Test func readsTheUpstreamTipsOfActiveBranchesWhereAServiceCanBeAsked() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        // A remote on this disk has no service to ask.
        #expect(try await ReviewModel.read(at: scratch.workURL, id: UUID(), name: "work").tips.isEmpty)
        try await scratch.work.setURL("https://github.com/octo/project.git", ofRemote: "origin")
        // A commit not pushed: the checks are those of what the remote has.
        let pushed = try #require(try await scratch.work.head().target)
        try await scratch.commit("Local", in: scratch.work, at: scratch.workURL)
        var read = try await ReviewModel.read(at: scratch.workURL, id: UUID(), name: "work")
        #expect(read.tips.map(\.branch) == [scratch.mainName, "topic"])
        #expect(read.tips.map(\.upstream) == ["origin/" + scratch.mainName, "origin/topic"])
        #expect(read.tips.map(\.commit) == [pushed, pushed])
        #expect(read.status.ahead == 1)
        #expect(read.status.branch == scratch.mainName)
        #expect(!read.status.hasUncommittedChanges)
        // A branch archived in the sidebar is not an active one.
        var layout = RepositoryInterfaceState.Stored()
        layout.archived = ["refs/heads/topic"]
        read = try await ReviewModel.read(at: scratch.workURL, id: UUID(), name: "work", layout: layout)
        #expect(read.tips.map(\.branch) == [scratch.mainName])
    }

    @Test func saysWhereADetachedHeadIs() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let commit = try #require(try await scratch.work.head().target)
        try await scratch.work.checkOut(commit: commit)
        let review = try await ReviewModel.read(at: scratch.workURL, id: UUID(), name: "work").review
        #expect(review.branch == nil)
        #expect(review.detachedAt == commit.abbreviated())
        #expect(review.matches(commit.abbreviated()))
        #expect(!review.needsAttention)
    }

    @Test func showsARepositoryWhoseBranchFailedItsChecks() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        try await scratch.work.setURL("https://github.com/octo/project.git", ofRemote: "origin")
        let tip = try #require(try await scratch.work.head().target)
        let library = RepositoryLibrary(
            storage: scratch.folder.appending(path: "Repositories.json"),
            documents: scratch.folder.appending(path: "Documents"), filesStorage: nil
        )
        let bookmark = try #require(library.listedBookmarks.first)
        let accounts = AccountStore(secrets: MemorySecretStore(), preferences: MemoryAccountPreferences())
        try accounts.save(
            HostingAccount(kind: .github, host: "github.com", login: "octo", signIn: .token), secret: HostingSecret(token: "tok")
        )
        // Pull requests and checks are both asked of GitHub's one address, so each has its own answers.
        let pullRequests = StubTransport()
        pullRequests.on("POST", "/graphql", json: ReviewRequestsTests.searchJSON(nodes: ""))
        let checks = StubTransport()
        checks.on("POST", "/graphql", json: #"{"data":{"repository":{"c0":{"statusCheckRollup":{"state":"FAILURE"}}}}}"#)
        let requests = ReviewRequests(accounts: accounts, transport: pullRequests)
        let model = ReviewModel(
            requests: requests, checks: ReviewChecks(accounts: accounts, transport: checks, gate: requests.gate)
        )

        #expect(!model.hasLoaded)
        await model.load(library.listedBookmarks, from: library)
        #expect(model.hasLoaded)
        #expect(model.missing.isEmpty)
        let review = try #require(model.reviews[bookmark.id])
        // Both branches are at the one commit, which is asked about once.
        let query = try #require(checks.last("POST", "/graphql")?.jsonBody?["query"] as? String)
        #expect(query.contains(#"c0: object(oid: "\#(tip.hex)")"#))
        #expect(!query.contains("c1:"))
        #expect(review.failedChecks.map(\.branch) == [scratch.mainName, "topic"])
        #expect(review.failedChecks.first?.commit == tip)
        #expect(review.failedChecks.first?.webURL?.absoluteString == "https://github.com/octo/project/commit/\(tip.hex)/checks")
        #expect(!review.hasWork)
        #expect(review.needsAttention)
        #expect(review.summary == "checks failed on 2 branches")
        #expect(ReviewTotals(Array(model.reviews.values)).sentence == "2 branches with failed checks in 1 repository")

        // Read again, it is shown from the start with what was last heard, and nobody is asked.
        await model.load(library.listedBookmarks, from: library)
        #expect(model.reviews[bookmark.id]?.failedChecks.count == 2)
        #expect(checks.requests.count == 1)

        // Its folder gone, it is missing and nothing is known of it.
        try FileManager.default.removeItem(at: scratch.workURL.appending(path: ".git"))
        await model.load([bookmark], from: library)
        #expect(model.missing == [bookmark.id])
        #expect(model.reviews[bookmark.id] == nil)
    }
}
