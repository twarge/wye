import Foundation
import GitKit
import Synchronization
import Testing
@testable import WyeUI

/// The checks of commits: what GitHub and GitLab are asked and how their
/// answers read, written from responses of both; and the store that keeps
/// the answers and decides when to ask again.
@MainActor
@Suite struct CommitCheckTests {
    static let repo = RepositoryPath(owner: "octo", name: "project")
    static let one = String(repeating: "1", count: 40)
    static let two = String(repeating: "2", count: 40)
    static let three = String(repeating: "3", count: 40)

    // MARK: GitHub

    @Test func gitHubAsksAboutManyCommitsAtOnce() async throws {
        let stub = StubTransport()
        stub.on("POST", "/graphql", json: """
        {"data":{"repository":{"c0":{"statusCheckRollup":{"state":"SUCCESS"}},"c1":{"statusCheckRollup":null},"c2":null}}}
        """)
        let statuses = try await stubService(.github, transport: stub)
            .checkStatuses(in: Self.repo, commits: [Self.one, Self.two, Self.three, "not a hash\" }"])
        // No checks, and not on the service, both read as none.
        #expect(statuses == [Self.one: .success])
        #expect(stub.requests.count == 1)
        let body = try #require(stub.last("POST", "/graphql")?.jsonBody)
        let query = try #require(body["query"] as? String)
        #expect(query.contains(#"c0: object(oid: "\#(Self.one)")"#))
        #expect(query.contains(#"c2: object(oid: "\#(Self.three)")"#))
        // Only hashes are written into the query.
        #expect(!query.contains("not a hash"))
        #expect((body["variables"] as? [String: Any])?["owner"] as? String == "octo")
    }

    @Test func gitHubWithoutTheRepositoryIsNotFound() async throws {
        let stub = StubTransport()
        stub.on("POST", "/graphql", json: #"{"data":{"repository":null}}"#)
        await #expect(throws: HostingError.notFound(host: "github.com")) {
            _ = try await stubService(.github, transport: stub).checkStatuses(in: Self.repo, commits: [Self.one])
        }
    }

    @Test func gitHubListsCheckRunsAndStatusesAcrossPages() async throws {
        let stub = StubTransport()
        stub.on("POST", "/graphql", json: """
        {"data":{"repository":{"object":{"statusCheckRollup":{"state":"FAILURE","contexts":{
          "pageInfo":{"hasNextPage":true,"endCursor":"Mg"},"nodes":[
          {"__typename":"CheckRun","databaseId":129076610119,"name":"Unit tests / Linux (6.1)","status":"COMPLETED",
           "conclusion":"SUCCESS","detailsUrl":"https://github.com/octo/project/actions/runs/4/job/129076610119",
           "startedAt":"2026-11-09T09:18:00Z","completedAt":"2026-11-09T09:21:52Z",
           "checkSuite":{"app":{"name":"GitHub Actions"},"workflowRun":{"workflow":{"name":"Main"}}}},
          {"__typename":"CheckRun","databaseId":7,"name":"Soundness","status":"COMPLETED","conclusion":"CANCELLED",
           "detailsUrl":"https://github.com/octo/project/actions/runs/4/job/7","startedAt":null,"completedAt":null,
           "checkSuite":{"app":{"name":"GitHub Actions"},"workflowRun":{"workflow":{"name":"Main"}}}}]}}}}}}
        """, once: true)
        stub.on("POST", "/graphql", json: """
        {"data":{"repository":{"object":{"statusCheckRollup":{"state":"FAILURE","contexts":{
          "pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
          {"__typename":"CheckRun","databaseId":8,"name":"lint","status":"IN_PROGRESS","conclusion":null,
           "detailsUrl":"https://ci.example/8","startedAt":"2026-11-09T09:18:00Z","completedAt":null,
           "checkSuite":{"app":{"name":"Linter"},"workflowRun":null}},
          {"__typename":"StatusContext","context":"ci/build","state":"SUCCESS","description":"Build passed",
           "targetUrl":"https://ci.example/build/1","createdAt":"2026-11-09T09:30:00Z"}]}}}}}}
        """)
        let checks = try await stubService(.github, transport: stub).checks(in: Self.repo, commit: Self.one)
        #expect(checks.status == .failure)
        #expect(checks.runs.map(\.name) == ["Unit tests / Linux (6.1)", "Soundness", "lint", "ci/build"])
        #expect(checks.runs.map(\.status) == [.success, .failure, .pending, .success])
        // The workflow, the app that is not Actions, and none for a status.
        #expect(checks.runs.map(\.group) == ["Main", "Main", "Linter", nil])
        #expect(checks.runs.map(\.detail) == [nil, "Cancelled", "Running", "Build passed"])
        #expect(checks.runs[0].duration == 232)
        #expect(checks.runs[0].url?.absoluteString == "https://github.com/octo/project/actions/runs/4/job/129076610119")
        #expect(Set(checks.runs.map(\.id)).count == 4)
        let second = try #require(stub.requests.last?.jsonBody?["variables"] as? [String: Any])
        #expect(second["after"] as? String == "Mg")
        #expect(second["oid"] as? String == Self.one)
    }

    @Test func gitHubCheckRunConclusions() {
        #expect(GitHubService.checkRunStatus(status: "COMPLETED", conclusion: "SUCCESS").0 == .success)
        #expect(GitHubService.checkRunStatus(status: "COMPLETED", conclusion: "TIMED_OUT") == (.failure, "Timed Out"))
        #expect(GitHubService.checkRunStatus(status: "COMPLETED", conclusion: "SKIPPED") == (.neutral, "Skipped"))
        #expect(GitHubService.checkRunStatus(status: "QUEUED", conclusion: nil) == (.pending, "Queued"))
        #expect(GitHubService.isHash(Self.one))
        #expect(!GitHubService.isHash("abc"))
        #expect(!GitHubService.isHash(String(repeating: "g", count: 40)))
    }

    // MARK: GitLab

    @Test func gitLabTakesTheNewestPipelineOfEachReference() async throws {
        let stub = StubTransport()
        // Newest first: the failure on `main` was run again and passed; the
        // merge request's own pipeline still runs.
        stub.on("POST", "gitlab.com/api/graphql", json: """
        {"data":{"project":{
          "c0":{"nodes":[{"status":"SUCCESS","ref":"main"},{"status":"RUNNING","ref":"refs/merge-requests/7/head"},
                         {"status":"FAILED","ref":"main"}]},
          "c1":{"nodes":[{"status":"SUCCESS","ref":"main"},{"status":"SKIPPED","ref":"v1"}]},
          "c2":{"nodes":[]}}}}
        """)
        let statuses = try await stubService(.gitlab, transport: stub)
            .checkStatuses(in: Self.repo, commits: [Self.one, Self.two, Self.three])
        #expect(statuses == [Self.one: .pending, Self.two: .success])
        let body = try #require(stub.last("POST", "/api/graphql")?.jsonBody)
        #expect((body["variables"] as? [String: Any])?["path"] as? String == "octo/project")
        #expect((body["query"] as? String)?.contains(#"c1: pipelines(sha: "\#(Self.two)", first: 10)"#) == true)
    }

    @Test func gitLabAsksForFewerWhenTheQueryIsTooComplex() async throws {
        let stub = StubTransport()
        stub.on("POST", "/api/graphql", json: """
        {"errors":[{"message":"Query has complexity of 211, which exceeds max complexity of 200"}]}
        """, once: true)
        stub.on("POST", "/api/graphql", json: #"{"data":{"project":{"c0":{"nodes":[{"status":"FAILED","ref":"main"}]}}}}"#)
        let statuses = try await stubService(.gitlab, transport: stub).checkStatuses(in: Self.repo, commits: [Self.one, Self.two])
        // Each half was asked for as its own `c0`.
        #expect(statuses == [Self.one: .failure, Self.two: .failure])
        #expect(stub.requests.count == 3)
    }

    @Test func gitLabWithoutTheProjectIsNotFound() async throws {
        let stub = StubTransport()
        stub.on("POST", "/api/graphql", json: #"{"data":{"project":null}}"#)
        await #expect(throws: HostingError.notFound(host: "gitlab.com")) {
            _ = try await stubService(.gitlab, transport: stub).checkStatuses(in: Self.repo, commits: [Self.one])
        }
        let selfManaged = try #require(stubService(.gitlab, host: "git.example.com", transport: stub) as? GitLabService)
        #expect(selfManaged.graphQLURL.absoluteString == "https://git.example.com/api/graphql")
    }

    @Test func gitLabListsTheJobsOfEachPipeline() async throws {
        let stub = StubTransport()
        stub.on("GET", "/pipelines?per_page=20&sha=\(Self.one)", json: """
        [{"id":47,"iid":12,"project_id":1,"status":"failed","source":"push","ref":"main","sha":"\(Self.one)","name":null,
          "web_url":"https://gitlab.com/octo/project/-/pipelines/47","created_at":"2026-11-13T18:13:00.154Z","updated_at":"2026-11-13T19:53:06.887Z"},
         {"id":46,"iid":11,"status":"success","source":"external","ref":"refs/merge-requests/7/train","sha":"\(Self.one)",
          "web_url":"https://gitlab.com/octo/project/-/pipelines/46","created_at":"2026-11-13T18:00:00.000Z","updated_at":"2026-11-13T18:05:00.000Z"},
         {"id":40,"iid":9,"status":"success","source":"push","ref":"main","sha":"\(Self.one)",
          "web_url":"https://gitlab.com/octo/project/-/pipelines/40","created_at":"2026-11-13T17:00:00.000Z","updated_at":"2026-11-13T17:05:00.000Z"}]
        """)
        // Newest first, as GitLab lists them.
        stub.on("GET", "/pipelines/47/jobs", json: """
        [{"id":103,"status":"failed","stage":"test","name":"lint","allow_failure":true,"started_at":null,"finished_at":null,
          "web_url":"https://gitlab.com/octo/project/-/jobs/103"},
         {"id":102,"status":"failed","stage":"test","name":"rspec","allow_failure":false,
          "started_at":"2026-11-13T18:35:22.457Z","finished_at":"2026-11-13T18:38:50.969Z","duration":208.5,
          "web_url":"https://gitlab.com/octo/project/-/jobs/102"},
         {"id":101,"status":"success","stage":"build","name":"compile","allow_failure":false,
          "web_url":"https://gitlab.com/octo/project/-/jobs/101"}]
        """)
        stub.on("GET", "/pipelines/46/jobs", json: "[]")
        let checks = try await stubService(.gitlab, transport: stub).checks(in: Self.repo, commit: Self.one)
        #expect(checks.status == .failure)
        // In the order of their stages; the superseded pipeline is left out;
        // one whose jobs are not listed stands as itself.
        #expect(checks.runs.map(\.name) == ["compile", "rspec", "lint", "Pipeline #11"])
        #expect(checks.runs.map(\.group) == ["main · build", "main · test", "main · test", "!7 train"])
        #expect(checks.runs.map(\.status) == [.success, .failure, .neutral, .success])
        #expect(checks.runs[2].detail == "Failed, Allowed")
        #expect(checks.runs[1].url?.absoluteString == "https://gitlab.com/octo/project/-/jobs/102")
        #expect(stub.last("GET", "/pipelines/40/jobs") == nil)
        #expect(GitLabService.referenceTitle("refs/merge-requests/7/head") == "!7")
    }

    // MARK: Presentation

    @Test func mergesAndTallies() {
        #expect(CheckStatus.merged([.success, .neutral, .success]) == .success)
        #expect(CheckStatus.merged([.success, .pending]) == .pending)
        #expect(CheckStatus.merged([.pending, .failure, .success]) == .failure)
        #expect(CheckStatus.merged([.neutral]) == .neutral)
        #expect(CheckStatus.merged([]) == nil)

        func run(_ name: String, _ group: String?, _ status: CheckStatus) -> CheckRun {
            CheckRun(id: name, name: name, group: group, status: status)
        }
        let runs = [run("a", "Build", .success), run("b", "Test", .failure), run("c", "Build", .success), run("d", nil, .pending)]
        // Failing groups first, then those running, each in its own order.
        #expect(runs.grouped.map(\.title) == ["Test", nil, "Build"])
        #expect(runs.grouped.last?.runs.map(\.name) == ["a", "c"])
        #expect(runs.tally(overall: .failure) == "1 of 4 checks failed")
        #expect([run("a", nil, .success), run("b", nil, .success)].tally(overall: .success) == "All 2 checks passed")
        #expect([run("a", nil, .success), run("b", nil, .neutral)].tally(overall: .success) == "1 of 2 checks passed")
        #expect([run("a", nil, .pending)].tally(overall: .pending) == "1 of 1 check running")
    }

    // MARK: The store

    /// A clock the test moves.
    final class Clock: Sendable {
        private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

        var now: Date { date.withLock { $0 } }

        func advance(_ seconds: TimeInterval) {
            date.withLock { $0 += seconds }
        }
    }

    private func commit(_ hash: String, age: TimeInterval, at clock: Clock) -> Commit {
        let signature = Signature(name: "A", email: "a@example.com", date: clock.now.addingTimeInterval(-age))
        return Commit(
            id: OID(hex: hash)!, parentIDs: [], treeID: OID(hex: hash)!, author: signature, committer: signature,
            summary: "S", body: ""
        )
    }

    private func source(_ kind: HostingKind, _ stub: StubTransport, account: UUID = UUID()) -> CheckSource {
        let hosted = HostedRepository(remoteURL: "https://\(kind.defaultHost)/octo/project.git", knownHosts: [:])!
        return CheckSource(
            key: hosted.key, remote: kind.rawValue, kind: kind, path: Self.repo, hosted: hosted, accountID: account,
            service: stubService(kind, transport: stub)
        )
    }

    private func gitHubAnswer(_ states: [String?]) -> String {
        let fields = states.enumerated().map { index, state in
            #""c\#(index)":"# + (state.map { #"{"statusCheckRollup":{"state":"\#($0)"}}"# } ?? "null")
        }
        return #"{"data":{"repository":{\#(fields.joined(separator: ","))}}}"#
    }

    @Test func failsIfAnyServiceFailed() async throws {
        let clock = Clock()
        let gitHub = StubTransport(), gitLab = StubTransport()
        gitHub.on("POST", "/graphql", json: gitHubAnswer(["SUCCESS", "SUCCESS", nil]))
        gitLab.on("POST", "/api/graphql", json: """
        {"data":{"project":{"c0":{"nodes":[{"status":"FAILED","ref":"main"}]},"c1":{"nodes":[]},"c2":{"nodes":[]}}}}
        """)
        let store = CommitCheckStore(repositoryName: "project", cache: nil) { clock.now }
        let commits = [Self.one, Self.two, Self.three].map { commit($0, age: 86_400, at: clock) }
        store.show(commits, tips: [], sources: [source(.github, gitHub), source(.gitlab, gitLab)])
        await store.refresh()
        #expect(store.statuses == [commits[0].id: .failure, commits[1].id: .success])
        #expect(store.sections(for: commits[0].id).map(\.source.kind) == [.github, .gitlab])
        #expect(store.sections(for: commits[2].id).isEmpty)

        // Signed out of GitLab: its answers no longer count.
        store.show(commits, tips: [], sources: [source(.github, gitHub)])
        #expect(store.statuses[commits[0].id] == .success)
        // And with nothing to ask, nothing is shown.
        store.show(commits, tips: [], sources: [])
        #expect(store.statuses.isEmpty)
    }

    @Test func asksAgainOnlyOnceAnAnswerHasAged() async throws {
        let clock = Clock()
        let stub = StubTransport()
        stub.on("POST", "/graphql", json: gitHubAnswer(["PENDING", "SUCCESS"]), once: true)
        stub.on("POST", "/graphql", json: gitHubAnswer(["SUCCESS"]))
        let store = CommitCheckStore(repositoryName: "project", cache: nil) { clock.now }
        // A commit of ten minutes ago and one of last week.
        let commits = [commit(Self.one, age: 600, at: clock), commit(Self.two, age: 7 * 86_400, at: clock)]
        let github = source(.github, stub)
        store.show(commits, tips: [], sources: [github])
        await store.refresh()
        #expect(store.statuses == [commits[0].id: .pending, commits[1].id: .success])
        #expect(store.pollInterval == .seconds(20))
        await store.refresh()
        #expect(stub.requests.count == 1)

        // Half a minute on, only what was running is asked about.
        clock.advance(30)
        await store.refresh()
        #expect(stub.requests.count == 2)
        #expect((stub.requests.last?.jsonBody?["query"] as? String)?.contains(Self.two) == false)
        #expect(store.statuses[commits[0].id] == .success)
        #expect(store.pollInterval == .seconds(60))

        // Asked to read again, everything is.
        store.reload()
        stub.on("POST", "/graphql", json: gitHubAnswer(["SUCCESS", "SUCCESS"]))
        await store.refresh()
        #expect(stub.requests.count == 3)
        #expect((stub.requests.last?.jsonBody?["query"] as? String)?.contains(Self.two) == true)
    }

    @Test func watchesBranchTipsAfterAPush() async throws {
        let clock = Clock()
        let stub = StubTransport()
        stub.on("POST", "/graphql", json: gitHubAnswer([nil, nil]), once: true)
        stub.on("POST", "/graphql", json: gitHubAnswer(["PENDING"]))
        let store = CommitCheckStore(repositoryName: "project", cache: nil) { clock.now }
        let commits = [commit(Self.one, age: 3 * 86_400, at: clock), commit(Self.two, age: 3 * 86_400, at: clock)]
        store.show(commits, tips: [commits[0].id], sources: [source(.github, stub)])
        await store.refresh()
        #expect(store.statuses.isEmpty)
        // Days old with no checks: not asked about again for hours.
        clock.advance(3_600)
        await store.refresh()
        #expect(stub.requests.count == 1)

        // Pushed: the branch's commit is asked about within seconds.
        let epoch = store.epoch
        store.remotesChanged()
        #expect(store.epoch == epoch + 1)
        #expect(store.pollInterval == .seconds(10))
        await store.refresh()
        #expect(stub.requests.count == 2)
        let query = try #require(stub.requests.last?.jsonBody?["query"] as? String)
        #expect(query.contains(Self.one) && !query.contains(Self.two))
        #expect(store.statuses == [commits[0].id: .pending])
    }

    @Test func leavesAFailingServiceAloneForAWhile() async throws {
        let clock = Clock()
        let stub = StubTransport()
        stub.on("POST", "/graphql", status: 401, json: #"{"message":"Bad credentials"}"#)
        let store = CommitCheckStore(repositoryName: "project", cache: nil) { clock.now }
        let commits = [commit(Self.one, age: 60, at: clock)]
        let account = UUID()
        store.show(commits, tips: [], sources: [source(.github, stub, account: account)])
        await store.refresh()
        clock.advance(120)
        await store.refresh()
        #expect(stub.requests.count == 1)
        #expect(store.statuses.isEmpty)
        // Signed in again, as another account: asked at once.
        store.show(commits, tips: [], sources: [source(.github, stub)])
        await store.refresh()
        #expect(stub.requests.count == 2)
    }

    @Test func keepsAnswersBetweenLaunches() async throws {
        let clock = Clock()
        let directory = FileManager.default.temporaryDirectory.appending(path: "wye-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CheckCache(directory: directory)
        let stub = StubTransport()
        stub.on("POST", "/graphql", json: gitHubAnswer(["FAILURE", nil]), once: true)
        stub.on("POST", "/graphql", json: """
        {"data":{"repository":{"object":{"statusCheckRollup":{"state":"FAILURE","contexts":{"pageInfo":{"hasNextPage":false},
          "nodes":[{"__typename":"StatusContext","context":"ci/build","state":"FAILURE","description":"Broke","targetUrl":null,
                    "createdAt":"2026-11-09T09:30:00Z"}]}}}}}}
        """)
        let commits = [commit(Self.one, age: 40 * 86_400, at: clock), commit(Self.two, age: 40 * 86_400, at: clock)]
        let github = source(.github, stub)
        let first = CommitCheckStore(repositoryName: "project", cache: cache) { clock.now }
        first.show(commits, tips: [], sources: [github])
        await first.refresh()
        await first.loadRuns(for: commits[0].id)
        #expect(first.sections(for: commits[0].id).first?.entry.runs?.map(\.name) == ["ci/build"])
        #expect(first.runFailures.isEmpty)
        await first.saveNow()
        #expect(FileManager.default.fileExists(atPath: cache.file(for: "github.com/octo/project").path))

        // The next launch, a day later: shown from the file, nothing asked.
        clock.advance(86_400)
        let second = CommitCheckStore(repositoryName: "project", cache: cache) { clock.now }
        second.show(commits, tips: [], sources: [github])
        let asked = stub.requests.count
        await second.refresh()
        #expect(stub.requests.count == asked)
        #expect(second.statuses == [commits[0].id: .failure])
        #expect(second.sections(for: commits[0].id).first?.entry.runs?.first?.detail == "Broke")
    }

    @Test func answersAgeByWhatTheySayAndHowOldTheCommitIs() {
        let hour: TimeInterval = 3_600
        #expect(CommitCheckStore.lifetime(of: .pending, commitAge: 60, isWatched: false) == 20)
        #expect(CommitCheckStore.lifetime(of: .pending, commitAge: 48 * hour, isWatched: false) == 300)
        #expect(CommitCheckStore.lifetime(of: nil, commitAge: 60, isWatched: false) == 45)
        #expect(CommitCheckStore.lifetime(of: nil, commitAge: 48 * hour, isWatched: true) == 10)
        #expect(CommitCheckStore.lifetime(of: .success, commitAge: 48 * hour, isWatched: true) == 12 * hour)
        #expect(CommitCheckStore.lifetime(of: .failure, commitAge: 90 * 24 * hour, isWatched: false) == 7 * 24 * hour)
    }

    @Test func theFileKeepsTheNewestAnswers() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var entries: [OID: CommitCheckStore.Entry] = [:]
        for index in 0..<6 {
            let date = start.addingTimeInterval(TimeInterval(index))
            entries[OID(hex: String(repeating: String(index), count: 40))!] = CommitCheckStore.Entry(
                status: .success, fetchedAt: date, runs: [], runsFetchedAt: date
            )
        }
        let kept = CheckCache.trimmed(entries, limit: 4, runsLimit: 2)
        #expect(Set(kept.keys) == Set((2..<6).map { String(repeating: String($0), count: 40) }))
        #expect(kept.values.count { $0.runs != nil } == 2)
        #expect(kept[String(repeating: "5", count: 40)]?.runs != nil)
        // A file name for any repository, whatever its path holds.
        let file = CheckCache(directory: URL(filePath: "/tmp/checks")).file(for: "git.example.com:8443/group/sub/project")
        #expect(file.lastPathComponent == "git.example.com%3A8443%2Fgroup%2Fsub%2Fproject.json")
    }
}
