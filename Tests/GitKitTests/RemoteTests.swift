import Foundation
import GitKit
import Testing

/// Fetch, push, pull and clone against bare repositories on disk, made and
/// inspected with the command line git.
@Suite struct RemoteTests {
    /// The repository GitKit works in, with `origin` set up and `main`
    /// tracking `origin/main`.
    let local: Fixture
    /// The bare repository standing as `origin`.
    let remote: URL
    /// Another clone of `origin`, standing for someone else's work.
    let other: URL

    init() throws {
        local = try Fixture()
        try local.commit("a.txt", "one\n", message: "First")
        remote = local.url.appendingPathExtension("remote.git")
        other = local.url.appendingPathExtension("other")
        try local.git("clone", "--quiet", "--bare", ".", remote.path)
        try local.git("remote", "add", "origin", remote.path)
        try local.git("fetch", "--quiet", "origin")
        try local.git("branch", "--set-upstream-to=origin/main")
        try local.git("clone", "--quiet", remote.path, other.path)
        try otherGit("config", "user.name", "Other Author")
        try otherGit("config", "user.email", "other@example.com")
    }

    private func remove() {
        local.remove()
        try? FileManager.default.removeItem(at: remote)
        try? FileManager.default.removeItem(at: other)
    }

    @discardableResult
    private func otherGit(_ arguments: String...) throws -> String {
        try Fixture.run(arguments, in: other)
    }

    @discardableResult
    private func remoteGit(_ arguments: String...) throws -> String {
        try Fixture.run(arguments, in: remote)
    }

    /// Commits a file in the other clone and pushes it to `origin`.
    @discardableResult
    private func otherCommitAndPush(_ path: String, _ text: String, message: String) throws -> String {
        let file = other.appending(path: path)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try otherGit("add", path)
        try otherGit("commit", "--quiet", "-m", message)
        try otherGit("push", "--quiet", "origin", "HEAD")
        return try otherGit("rev-parse", "HEAD")
    }

    // MARK: Fetch

    @Test func fetchBringsNewCommitsAndPrunesDeletedBranches() async throws {
        defer { remove() }
        try remoteGit("branch", "old", "main")
        try local.git("fetch", "--quiet", "origin")
        #expect(try local.git("branch", "-r").contains("origin/old"))

        let pushed = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try otherGit("push", "--quiet", "origin", "HEAD:refs/heads/feature")
        try otherGit("push", "--quiet", "origin", "--delete", "old")

        let transfer = Transfer()
        let reports = Task { await transfer.progress.reduce(into: []) { $0.append($1) } }
        try await local.open().fetch(transfer: transfer)

        #expect(try local.git("rev-parse", "origin/main") == pushed)
        #expect(try local.git("rev-parse", "origin/feature") == pushed)
        let remoteBranches = try local.git("for-each-ref", "--format=%(refname)", "refs/remotes")
            .split(separator: "\n")
        // `origin/HEAD` is from the command line fetch in `init`.
        #expect(remoteBranches == ["refs/remotes/origin/HEAD", "refs/remotes/origin/feature", "refs/remotes/origin/main"])
        // A fetch moves only remote branches.
        #expect(try local.git("rev-parse", "main") != pushed)
        // Reports are dropped when they come faster than they are read, but
        // the final count always arrives.
        let last = try #require(await reports.value.last)
        #expect([.receivingObjects, .resolvingDeltas].contains(last.phase))
        #expect(last.total > 0 && last.completed == last.total)
    }

    @Test func fetchWithoutPruneKeepsDeletedBranches() async throws {
        defer { remove() }
        try remoteGit("branch", "old", "main")
        try local.git("fetch", "--quiet", "origin")
        try remoteGit("branch", "-D", "old")

        try await local.open().fetch(remote: "origin", prune: false)
        #expect(try local.git("branch", "-r").contains("origin/old"))
        try await local.open().fetch(remote: "origin", prune: true)
        #expect(!(try local.git("branch", "-r").contains("origin/old")))
    }

    @Test func fetchAllFetchesEveryRemote() async throws {
        defer { remove() }
        let second = local.url.appendingPathExtension("second.git")
        defer { try? FileManager.default.removeItem(at: second) }
        try local.git("clone", "--quiet", "--bare", remote.path, second.path)
        try local.git("remote", "add", "second", second.path)
        let pushed = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try otherGit("push", "--quiet", second.path, "HEAD:refs/heads/main")

        try await local.open().fetch()
        #expect(try local.git("rev-parse", "origin/main") == pushed)
        #expect(try local.git("rev-parse", "second/main") == pushed)
    }

    @Test func fetchFromAnUnknownRemoteFails() async throws {
        defer { remove() }
        await #expect(throws: RemoteError.remoteNotFound("nowhere")) {
            try await local.open().fetch(remote: "nowhere")
        }
    }

    @Test func anSSHRemoteThatCannotBeReachedFailsWithAClearError() async throws {
        defer { remove() }
        // Port 9 on this machine: nothing listens there.
        try local.git("remote", "add", "ssh", "ssh://git@127.0.0.1:9/owner/project.git")
        await #expect {
            try await local.open().fetch(remote: "ssh")
        } throws: { error in
            guard case RemoteError.sshConnectionFailed(let host, _) = error else { return false }
            return host == "127.0.0.1"
        }
    }

    // MARK: Push

    @Test func pushUpdatesTheRemoteBranch() async throws {
        defer { remove() }
        let head = try local.commit("a.txt", "two\n", message: "Second")

        let transfer = Transfer()
        let reports = Task { await transfer.progress.reduce(into: []) { $0.append($1) } }
        let result = try await local.open().push(transfer: transfer)

        #expect(result == PushResult(remote: "origin", reference: "refs/heads/main", setUpstream: false))
        #expect(try remoteGit("rev-parse", "main") == head)
        // The remote branch here moves along with it.
        #expect(try local.git("rev-parse", "origin/main") == head)
        #expect(try local.git("status", "--porcelain=v2", "--branch").contains("# branch.ab +0 -0"))
        #expect(await !reports.value.isEmpty)
    }

    @Test func firstPushPublishesTheBranchAndSetsItsUpstream() async throws {
        defer { remove() }
        try local.git("checkout", "--quiet", "-b", "topic")
        let head = try local.commit("t.txt", "topic\n", message: "Topic")

        let result = try await local.open().push()

        #expect(result == PushResult(remote: "origin", reference: "refs/heads/topic", setUpstream: true))
        #expect(try remoteGit("rev-parse", "topic") == head)
        #expect(try local.git("rev-parse", "--abbrev-ref", "topic@{upstream}") == "origin/topic")
        let snapshot = try await local.open().snapshot()
        #expect(snapshot.branches.first { $0.name == "topic" }?.upstream?.name == "origin/topic")
    }

    @Test func pushRefusesToDropTheRemotesCommits() async throws {
        defer { remove() }
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try local.commit("a.txt", "two\n", message: "Mine")

        await #expect(throws: RemoteError.nonFastForward(branch: "main")) {
            try await local.open().push()
        }
        #expect(try remoteGit("rev-parse", "main") == theirs)
    }

    @Test func forcePushReplacesTheRemoteBranchItHasSeen() async throws {
        defer { remove() }
        try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try local.git("fetch", "--quiet", "origin")
        let mine = try local.commit("a.txt", "two\n", message: "Mine")

        try await local.open().push(force: true)
        #expect(try remoteGit("rev-parse", "main") == mine)
    }

    @Test func forcePushRefusesWhenTheRemoteMovedSinceTheLastFetch() async throws {
        defer { remove() }
        // Not fetched: the push would drop a commit nobody here has seen.
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try local.commit("a.txt", "two\n", message: "Mine")

        await #expect(throws: RemoteError.remoteMoved(branch: "main")) {
            try await local.open().push(force: true)
        }
        #expect(try remoteGit("rev-parse", "main") == theirs)
    }

    @Test func pushNeedsABranch() async throws {
        defer { remove() }
        try local.git("checkout", "--quiet", "--detach")
        await #expect(throws: RemoteError.notOnBranch) {
            try await local.open().push()
        }
    }

    // MARK: Pull

    @Test func pullFastForwards() async throws {
        defer { remove() }
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")

        let result = try await local.open().pull()

        #expect(result == .fastForwarded(to: OID(hex: theirs)!))
        #expect(try local.git("rev-parse", "HEAD") == theirs)
        #expect(try local.git("symbolic-ref", "HEAD") == "refs/heads/main")
        #expect(try String(contentsOf: local.url.appending(path: "b.txt"), encoding: .utf8) == "other\n")
        #expect(try local.git("status", "--porcelain").isEmpty)
    }

    @Test func pullKeepsUnrelatedLocalChanges() async throws {
        defer { remove() }
        try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try local.write("changed\n", to: "a.txt")

        _ = try await local.open().pull()
        #expect(try local.git("status", "--porcelain") == "M a.txt")
    }

    @Test func pullWhenUpToDateDoesNothing() async throws {
        defer { remove() }
        let head = try local.git("rev-parse", "HEAD")
        #expect(try await local.open().pull() == .upToDate)
        #expect(try local.git("rev-parse", "HEAD") == head)
    }

    @Test func pullMergesWhenBothSidesHaveCommits() async throws {
        defer { remove() }
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        let mine = try local.commit("c.txt", "mine\n", message: "Mine")

        let result = try await local.open().pull()

        let head = try local.git("rev-parse", "HEAD")
        #expect(result == .merged(commit: OID(hex: head)!))
        #expect(try local.git("rev-parse", "HEAD^1") == mine)
        #expect(try local.git("rev-parse", "HEAD^2") == theirs)
        #expect(try local.git("log", "-1", "--format=%s") == "Merge branch 'main' of \(remote.path)")
        #expect(try local.git("ls-tree", "--name-only", "HEAD").split(separator: "\n") == ["a.txt", "b.txt", "c.txt"])
        #expect(try local.git("status", "--porcelain").isEmpty)
        #expect(try await local.open().snapshot().state == .clean)
    }

    @Test func pullWithConflictsLeavesTheRepositoryMerging() async throws {
        defer { remove() }
        let theirs = try otherCommitAndPush("a.txt", "theirs\n", message: "Their change")
        let mine = try local.commit("a.txt", "mine\n", message: "My change")

        let result = try await local.open().pull()

        #expect(result == .conflicts(paths: ["a.txt"]))
        #expect(try local.git("rev-parse", "HEAD") == mine)
        #expect(try local.git("rev-parse", "MERGE_HEAD") == theirs)
        #expect(try local.git("status", "--porcelain") == "UU a.txt")
        let text = try String(contentsOf: local.url.appending(path: "a.txt"), encoding: .utf8)
        #expect(text.contains("<<<<<<<") && text.contains("mine") && text.contains("theirs"))
        let repository = try local.open()
        #expect(try await repository.snapshot().state == .merging)
        #expect(try await repository.status().first?.isConflicted == true)
    }

    @Test func pullNeedsAnUpstream() async throws {
        defer { remove() }
        try local.git("checkout", "--quiet", "-b", "topic")
        await #expect(throws: RemoteError.noUpstream(branch: "topic")) {
            try await local.open().pull()
        }
    }

    // MARK: Clone

    @Test func cloneChecksOutTheDefaultBranchAndTracksIt() async throws {
        defer { remove() }
        let head = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        let destination = local.url.appendingPathExtension("clone")
        defer { try? FileManager.default.removeItem(at: destination) }

        let transfer = Transfer()
        let reports = Task { await transfer.progress.reduce(into: []) { $0.append($1) } }
        let repository = try await Repository.clone(from: remote.path, to: destination, transfer: transfer)

        let git = { (arguments: [String]) in try Fixture.run(arguments, in: destination) }
        #expect(try git(["rev-parse", "HEAD"]) == head)
        #expect(try git(["symbolic-ref", "HEAD"]) == "refs/heads/main")
        #expect(try git(["remote", "get-url", "origin"]) == remote.path)
        #expect(try git(["rev-parse", "--abbrev-ref", "main@{upstream}"]) == "origin/main")
        #expect(try git(["status", "--porcelain"]).isEmpty)
        #expect(try await repository.snapshot().head == .branch(name: "refs/heads/main", target: OID(hex: head)!))
        let last = try #require(await reports.value.last)
        #expect(last.phase == .checkingOut && last.fractionCompleted == 1)
    }

    @Test func aCancelledCloneLeavesNothingBehind() async throws {
        defer { remove() }
        let destination = local.url.appendingPathExtension("clone")
        defer { try? FileManager.default.removeItem(at: destination) }
        let transfer = Transfer()
        transfer.cancel()

        // A file URL, so libgit2 transfers objects as over a network
        // instead of copying the remote's files.
        await #expect(throws: CancellationError.self) {
            _ = try await Repository.clone(from: remote.absoluteString, to: destination, transfer: transfer)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cloningFromAFileURLTransfersObjects() async throws {
        defer { remove() }
        let destination = local.url.appendingPathExtension("clone")
        defer { try? FileManager.default.removeItem(at: destination) }
        let transfer = Transfer()
        let reports = Task { await transfer.progress.reduce(into: []) { $0.append($1) } }

        _ = try await Repository.clone(from: remote.absoluteString, to: destination, transfer: transfer)

        #expect(try Fixture.run(["rev-parse", "HEAD"], in: destination) == local.git("rev-parse", "HEAD"))
        let last = try #require(await reports.value.last)
        #expect(last.phase == .checkingOut && last.fractionCompleted == 1)
    }

    @Test func cancellingTheTaskCancelsAFetch() async throws {
        defer { remove() }
        try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        let before = try local.git("rev-parse", "origin/main")
        let repository = try local.open()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await repository.fetch()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try local.git("rev-parse", "origin/main") == before)
    }

    // MARK: Remote management

    @Test func addRenameChangeAndRemoveRemotes() async throws {
        defer { remove() }
        let repository = try local.open()

        try await repository.addRemote(named: "upstream", url: "https://example.com/one.git")
        #expect(try local.git("remote", "get-url", "upstream") == "https://example.com/one.git")
        #expect(try local.git("config", "remote.upstream.fetch") == "+refs/heads/*:refs/remotes/upstream/*")

        try await repository.setURL("https://example.com/two.git", ofRemote: "upstream")
        #expect(try local.git("remote", "get-url", "upstream") == "https://example.com/two.git")

        let problems = try await repository.renameRemote("origin", to: "home")
        #expect(problems.isEmpty)
        #expect(try local.git("remote").split(separator: "\n") == ["home", "upstream"])
        // The remote branches and the upstream move with it.
        #expect(try local.git("rev-parse", "--abbrev-ref", "main@{upstream}") == "home/main")

        try await repository.removeRemote(named: "home")
        #expect(try local.git("remote") == "upstream")
        #expect(try local.git("for-each-ref", "refs/remotes").isEmpty)

        await #expect(throws: RemoteError.invalidRemoteName("no good")) {
            try await repository.addRemote(named: "no good", url: "https://example.com/three.git")
        }
    }
}
