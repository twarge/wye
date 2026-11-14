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

private func oid(_ character: Character) -> OID {
    OID(hex: String(repeating: character, count: 40))!
}

/// A local branch following the remote branch of its name, unless told otherwise.
private func local(_ name: String, at target: OID, isHead: Bool = false, upstream: String?? = .none) -> Branch {
    let followed: String? = switch upstream {
    case .none: "origin/" + name
    case .some(let named): named
    }
    return Branch(
        id: "refs/heads/" + name, name: name, target: target, isHead: isHead,
        upstream: followed.map { Branch.Upstream(name: $0, ahead: 0, behind: 0) }
    )
}

private func remote(_ name: String, at target: OID) -> Branch {
    Branch(id: "refs/remotes/" + name, name: name, target: target, isRemote: true)
}

/// Which branches the list of repositories asks about: the tips, on their
/// remotes, of those the sidebar counts as active.
@Suite struct BranchTipTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func tips(
        _ branches: [Branch], dates: [OID: Date], archived: [String] = [], pinned: [String] = [],
        staleMonths: Int = 3, autoArchiveMonths: Int = 0
    ) -> [BranchTip] {
        var layout = RepositoryInterfaceState.Stored()
        layout.archived = archived
        layout.pinned = pinned
        let head = branches.first { $0.isHead }
        // As a snapshot has them: local branches, and the remote's under it.
        let snapshot = RepositorySnapshot(
            head: head.map { .branch(name: $0.id, target: $0.target) } ?? .unborn(name: "refs/heads/main"),
            branches: branches.filter { !$0.isRemote },
            remotes: [Remote(name: "origin", url: nil, branches: branches.filter(\.isRemote))]
        )
        return BranchTip.active(
            in: snapshot, layout: layout, dates: dates, now: now, staleMonths: staleMonths,
            autoArchiveMonths: autoArchiveMonths, calendar: Calendar(identifier: .gregorian)
        )
    }

    @Test func asksAboutWhatTheRemoteHasNotWhatIsOnlyHere() {
        // `main` has a commit that is not pushed: the service ran checks for the one before.
        let found = tips(
            [local("main", at: oid("a"), isHead: true), remote("origin/main", at: oid("b"))],
            dates: [oid("a"): now, oid("b"): now.addingTimeInterval(-day)]
        )
        #expect(found == [
            BranchTip(branch: "main", upstream: "origin/main", commit: oid("b"), committed: now.addingTimeInterval(-day))
        ])
    }

    @Test func leavesOutBranchesNeverPublished() {
        let found = tips(
            [
                local("main", at: oid("a"), isHead: true), remote("origin/main", at: oid("a")),
                local("scratch", at: oid("c"), upstream: .some(nil)),
                // Its upstream was deleted on the remote and pruned here.
                local("gone", at: oid("d"))
            ],
            dates: [oid("a"): now, oid("c"): now, oid("d"): now]
        )
        #expect(found.map(\.branch) == ["main"])
    }

    @Test func leavesOutStaleAndArchivedBranches() {
        let old = now.addingTimeInterval(-200 * day)
        let branches = [
            local("main", at: oid("a"), isHead: true), remote("origin/main", at: oid("a")),
            local("topic", at: oid("b")), remote("origin/topic", at: oid("b")),
            local("dusty", at: oid("c")), remote("origin/dusty", at: oid("c")),
            local("shelved", at: oid("d")), remote("origin/shelved", at: oid("d"))
        ]
        let dates = [oid("a"): old, oid("b"): now.addingTimeInterval(-day), oid("c"): old, oid("d"): now]
        // The checked-out branch counts however old it is.
        #expect(tips(branches, dates: dates, archived: ["refs/heads/shelved"]).map(\.branch) == ["main", "topic"])
        // Told never to mark branches stale, age alone leaves none out…
        #expect(
            tips(branches, dates: dates, archived: ["refs/heads/shelved"], staleMonths: 0).map(\.branch)
                == ["main", "topic", "dusty"]
        )
        // …unless they are archived for it; a pinned one is not, though it is still stale.
        #expect(tips(branches, dates: dates, staleMonths: 0, autoArchiveMonths: 3).map(\.branch) == ["main", "shelved", "topic"])
        #expect(
            tips(branches, dates: dates, pinned: ["refs/heads/dusty"], staleMonths: 0, autoArchiveMonths: 3).map(\.branch)
                == ["main", "shelved", "topic", "dusty"]
        )
        #expect(tips(branches, dates: dates, pinned: ["refs/heads/dusty"]).map(\.branch) == ["main", "shelved", "topic"])
    }

    @Test func putsTheCheckedOutBranchFirstThenTheNewestAndStopsAtARequestsWorth() {
        var branches = [local("main", at: oid("a"), isHead: true), remote("origin/main", at: oid("a"))]
        var dates = [oid("a"): now.addingTimeInterval(-60 * day)]
        for index in 0..<40 {
            let id = OID(hex: String(format: "%040x", index + 1))!
            branches += [local("b\(index)", at: id), remote("origin/b\(index)", at: id)]
            dates[id] = now.addingTimeInterval(-Double(index) * 60)
        }
        let found = tips(branches, dates: dates)
        #expect(found.count == BranchTip.limit)
        #expect(found.prefix(3).map(\.branch) == ["main", "b0", "b1"])
    }
}

/// What a failed check makes of a repository's row and of the list's totals.
@Suite struct FailedCheckSummaryTests {
    private func failed(_ branch: String, upstream: String? = nil) -> FailedCheck {
        FailedCheck(branch: branch, upstream: upstream ?? "origin/" + branch, commit: oid("a"))
    }

    private func review(failedChecks: [FailedCheck] = [], ahead: Int = 0, reviewRequests: [ReviewRequest] = []) -> RepositoryReview {
        RepositoryReview(
            id: UUID(), name: "Wye", branch: "main", upstream: "origin/main", hasRemote: true, entries: [],
            commits: [], ahead: ahead, behind: 0, reviewRequests: reviewRequests, failedChecks: failedChecks
        )
    }

    @Test func saysWhichBranchFailedAndSeveralByTheirNumber() {
        #expect(review(failedChecks: [failed("main")]).summary == "checks failed on main")
        #expect(review(failedChecks: [failed("main"), failed("topic")]).summary == "checks failed on 2 branches")
        // After the work here and before what others ask for.
        let request = ReviewRequest(repository: "example.com/octo/project", kind: .github, number: 12, title: "Add login")
        #expect(
            review(failedChecks: [failed("main")], ahead: 1, reviewRequests: [request]).summary
                == "1 unpushed commit · checks failed on main · 1 pull request to review"
        )
    }

    @Test func aFailedCheckIsAReasonToLookButNotWork() {
        let item = review(failedChecks: [failed("release/2.0")])
        #expect(item.needsAttention)
        #expect(!item.hasWork)
        #expect(!review().needsAttention)
        // Found by its branch, among what the row folds away.
        #expect(item.matches("release"))
        #expect(item.hasFoldedMatch(for: "release"))
        #expect(!item.hasFoldedMatch(for: "Wye"))
        #expect(!item.hasFoldedMatch(for: " "))
    }

    @Test func saysWhereItFailedWhenTheUpstreamHasAnotherName() {
        #expect(failed("main").sentence == "Checks failed on “main”")
        #expect(failed("feature/login").sentence == "Checks failed on “feature/login”")
        #expect(failed("main", upstream: "origin/trunk").sentence == "Checks failed on “main”, at origin/trunk")
    }

    @Test func totalsBranchesWithFailedChecks() {
        #expect(ReviewTotals([review(failedChecks: [failed("main")])]).sentence == "1 branch with failed checks in 1 repository")
        let totals = ReviewTotals([
            review(failedChecks: [failed("main"), failed("topic")], ahead: 2), review(failedChecks: [failed("main")]), review()
        ])
        #expect(totals.failedChecks == 3)
        #expect(totals.sentence == "2 unpushed commits and 3 branches with failed checks in 2 repositories")
    }
}

/// The failed checks of branch tips: asked of recorded responses, with
/// accounts kept in memory, so nothing here reaches a service or the Keychain.
@MainActor
@Suite struct ReviewChecksTests {
    let stub = StubTransport()
    let accounts = AccountStore(secrets: MemorySecretStore(), preferences: MemoryAccountPreferences())
    private let clock = TestClock()

    private func checks(transport: (any HTTPTransport)? = nil) -> ReviewChecks {
        let clock = clock
        return ReviewChecks(
            accounts: accounts, transport: transport ?? stub,
            gate: ReviewServiceGate(concurrentRequests: 4, now: { clock.now }), now: { clock.now }
        )
    }

    private func signIn(_ kind: HostingKind = .github) throws {
        let account = HostingAccount(kind: kind, host: kind.defaultHost, login: "octo", signIn: .token)
        try accounts.save(account, secret: HostingSecret(token: "tok"))
    }

    private func origin(_ url: String = "https://github.com/octo/project.git") -> [Remote] {
        [Remote(name: "origin", url: url, branches: [])]
    }

    /// Tips committed two days before the clock's time: old enough for an
    /// answer about them to stand for hours.
    private func tip(_ branch: String, _ character: Character) -> BranchTip {
        BranchTip(
            branch: branch, upstream: "origin/" + branch, commit: oid(character),
            committed: clock.now.addingTimeInterval(-2 * 24 * 60 * 60)
        )
    }

    private static func rollups(_ states: String?...) -> String {
        let fields = states.enumerated().map { index, state in
            "\"c\(index)\":" + (state.map { "{\"statusCheckRollup\":{\"state\":\"\($0)\"}}" } ?? "{\"statusCheckRollup\":null}")
        }
        return "{\"data\":{\"repository\":{\(fields.joined(separator: ","))}}}"
    }

    @Test func asksAboutEveryTipAtOnceAndReportsTheOnesThatFailed() async throws {
        try signIn()
        stub.on("POST", "/graphql", json: Self.rollups("FAILURE", "SUCCESS", "PENDING", nil))
        let tips = [tip("main", "a"), tip("topic", "b"), tip("running", "c"), tip("quiet", "d")]
        let failed = await checks().failedChecks(for: origin(), tips: tips)
        #expect(failed == [
            FailedCheck(
                branch: "main", upstream: "origin/main", commit: oid("a"),
                webURL: URL(string: "https://github.com/octo/project/commit/\(oid("a").hex)/checks")
            )
        ])
        #expect(stub.requests.count == 1)
        let request = try #require(stub.last("POST", "/graphql"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let query = try #require(request.jsonBody?["query"] as? String)
        #expect(query.contains(#"c0: object(oid: "\#(oid("a").hex)")"#))
        #expect(query.contains(#"c3: object(oid: "\#(oid("d").hex)")"#))
    }

    @Test func keepsAnAnswerUntilItAges() async throws {
        try signIn()
        stub.on("POST", "/graphql", json: Self.rollups("FAILURE"), once: true)
        stub.on("POST", "/graphql", json: Self.rollups("SUCCESS"))
        let checks = checks()
        let tips = [tip("main", "a")]
        #expect(await checks.failedChecks(for: origin(), tips: tips).count == 1)
        // Heard a moment ago: another folder of the repository, or another reading, does not ask.
        clock.advance(60)
        #expect(await checks.failedChecks(for: origin("git@github.com:octo/project.git"), tips: tips).count == 1)
        #expect(stub.requests.count == 1)
        // Asked to read again, it asks whatever it heard lately; the checks have been run again and passed.
        #expect(await checks.failedChecks(for: origin(), tips: tips, asksAgain: true).isEmpty)
        #expect(stub.requests.count == 2)
        // What an old commit's checks came to stands for hours.
        clock.advance(60 * 60)
        _ = await checks.failedChecks(for: origin(), tips: tips)
        #expect(stub.requests.count == 2)
        clock.advance(12 * 60 * 60)
        _ = await checks.failedChecks(for: origin(), tips: tips)
        #expect(stub.requests.count == 3)
    }

    @Test func asksOnlyAboutTipsItHasNoAnswerFor() async throws {
        try signIn()
        stub.on("POST", "/graphql", json: Self.rollups("SUCCESS"), once: true)
        stub.on("POST", "/graphql", json: Self.rollups("FAILURE"))
        let checks = checks()
        #expect(await checks.failedChecks(for: origin(), tips: [tip("main", "a")]).isEmpty)
        // `main` moved on: only its new commit is asked about.
        let failed = await checks.failedChecks(for: origin(), tips: [tip("main", "b"), tip("topic", "a")])
        #expect(failed.map(\.branch) == ["main"])
        let query = try #require(stub.last("POST", "/graphql")?.jsonBody?["query"] as? String)
        #expect(query.contains(oid("b").hex))
        #expect(!query.contains(oid("a").hex))
    }

    @Test func asksNoOneWithoutAnAccountOrWhereChecksAreNotRead() async throws {
        #expect(await checks().failedChecks(for: origin(), tips: [tip("main", "a")]).isEmpty)
        // Bitbucket's checks are not read.
        try signIn(.bitbucket)
        let bitbucket = origin("https://bitbucket.org/octo/project.git")
        #expect(await checks().failedChecks(for: bitbucket, tips: [tip("main", "a")]).isEmpty)
        // No tips, nothing to ask.
        try signIn()
        #expect(await checks().failedChecks(for: origin(), tips: []).isEmpty)
        #expect(stub.requests.isEmpty)
    }

    @Test func keepsWhatWasHeardWhenAskingLaterFailsAndLeavesTheServiceAlone() async throws {
        try signIn()
        stub.on("POST", "/graphql", json: Self.rollups("FAILURE"), once: true)
        stub.on("POST", "/graphql", status: 502, json: #"{"message":"Bad gateway"}"#)
        let checks = checks()
        let tips = [tip("main", "a")]
        #expect(await checks.failedChecks(for: origin(), tips: tips).count == 1)
        clock.advance(13 * 60 * 60)
        #expect(await checks.failedChecks(for: origin(), tips: tips).count == 1)
        #expect(stub.requests.count == 2)
        // Left alone for a couple of minutes after it failed.
        #expect(await checks.failedChecks(for: origin(), tips: tips, asksAgain: true).count == 1)
        #expect(stub.requests.count == 2)
        clock.advance(3 * 60)
        _ = await checks.failedChecks(for: origin(), tips: tips)
        #expect(stub.requests.count == 3)
    }

    @Test func sharesItsAccountsAndItsGateWithThePullRequests() async throws {
        try signIn()
        let clock = clock
        let requests = ReviewRequests(accounts: accounts, transport: OfflineTransport(), now: { clock.now })
        // Offline for the pull requests: the account's checks are not tried either, for a while.
        _ = await requests.reviewRequests(for: origin())
        stub.on("POST", "/graphql", json: Self.rollups("FAILURE"))
        let checks = ReviewChecks(accounts: accounts, transport: stub, gate: requests.gate, now: { clock.now })
        #expect(await checks.failedChecks(for: origin(), tips: [tip("main", "a")]).isEmpty)
        #expect(stub.requests.isEmpty)
        clock.advance(31)
        #expect(await checks.failedChecks(for: origin(), tips: [tip("main", "a")]).count == 1)
        // The one a model gets when it is given none asks as the pull requests do.
        #expect(requests.checks === requests.checks)
    }
}
