import Foundation
import GitKit
import Testing

/// Relative remote URLs, pull modes, autostash, sync, pushing elsewhere,
/// tags and branches on a remote, checked against the command line git.
@Suite struct RemoteOptionsTests {
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

    private func remove(_ extra: URL...) {
        local.remove()
        try? FileManager.default.removeItem(at: remote)
        try? FileManager.default.removeItem(at: other)
        extra.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    @discardableResult
    private func otherGit(_ arguments: String...) throws -> String {
        try Fixture.run(arguments, in: other)
    }

    @discardableResult
    private func remoteGit(_ arguments: String...) throws -> String {
        try Fixture.run(arguments, in: remote)
    }

    @discardableResult
    private func otherCommitAndPush(_ path: String, _ text: String, message: String) throws -> String {
        try text.write(to: other.appending(path: path), atomically: true, encoding: .utf8)
        try otherGit("add", path)
        try otherGit("commit", "--quiet", "-m", message)
        try otherGit("push", "--quiet", "origin", "HEAD")
        return try otherGit("rev-parse", "HEAD")
    }

    /// A copy of the local repository, for the command line git to do the
    /// same thing in and compare.
    private func twin() throws -> URL {
        let twin = local.url.appendingPathExtension("twin")
        try FileManager.default.copyItem(at: local.url, to: twin)
        return twin
    }

    private func read(_ path: String, in directory: URL? = nil) throws -> String {
        try String(contentsOf: (directory ?? local.url).appending(path: path), encoding: .utf8)
    }

    // MARK: Relative and file URLs

    @Test func relativeRemoteURLsResolveFromTheTopOfTheWorkingTree() async throws {
        defer { remove() }
        let relative = "../" + remote.lastPathComponent
        try local.git("remote", "set-url", "origin", relative)
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")

        // git reads the path from the top of the working tree, wherever it runs.
        let twin = try twin()
        defer { try? FileManager.default.removeItem(at: twin) }
        try FileManager.default.createDirectory(at: twin.appending(path: "sub"), withIntermediateDirectories: true)
        _ = try Fixture.run(["fetch", "--quiet", "origin"], in: twin.appending(path: "sub"))

        let repository = try local.open()
        try await repository.fetch(remote: "origin")
        #expect(try local.git("rev-parse", "origin/main") == theirs)
        #expect(try Fixture.run(["rev-parse", "origin/main"], in: twin) == theirs)
        // The configuration keeps what the user wrote.
        #expect(try local.git("remote", "get-url", "origin") == relative)

        #expect(try await repository.pull() == .fastForwarded(to: OID(hex: theirs)!))
        let mine = try local.commit("c.txt", "mine\n", message: "Mine")
        try await repository.push()
        #expect(try remoteGit("rev-parse", "main") == mine)
    }

    @Test func aBareRepositoryResolvesFromItsOwnFolder() async throws {
        let bare = local.url.appendingPathExtension("bare.git")
        defer { remove(bare) }
        try local.git("clone", "--quiet", "--bare", ".", bare.path)
        _ = try Fixture.run(["remote", "add", "up", "../" + remote.lastPathComponent], in: bare)
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        _ = try Fixture.run(["fetch", "--quiet", "up"], in: bare)
        let gitFetched = try Fixture.run(["rev-parse", "up/main"], in: bare)
        _ = try Fixture.run(["update-ref", "-d", "refs/remotes/up/main"], in: bare)

        try await Repository(at: bare).fetch(remote: "up")
        #expect(try Fixture.run(["rev-parse", "up/main"], in: bare) == theirs)
        #expect(gitFetched == theirs)
    }

    @Test func aRelativePushURLResolvesToo() async throws {
        defer { remove() }
        try local.git("remote", "set-url", "--push", "origin", "./../" + remote.lastPathComponent)
        let mine = try local.commit("c.txt", "mine\n", message: "Mine")
        let repository = try local.open()
        try await repository.push()
        #expect(try remoteGit("rev-parse", "main") == mine)
        #expect(try await repository.pushURL(ofRemote: "origin") == "./../" + remote.lastPathComponent)
    }

    @Test func fileURLRemotesWork() async throws {
        defer { remove() }
        try local.git("remote", "set-url", "origin", remote.absoluteString)
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try await local.open().fetch(remote: "origin")
        #expect(try local.git("rev-parse", "origin/main") == theirs)
    }

    @Test func pushURLsCanBeSetAndCleared() async throws {
        defer { remove() }
        let repository = try local.open()
        try await repository.setPushURL("https://example.com/push.git", ofRemote: "origin")
        #expect(try local.git("remote", "get-url", "--push", "origin") == "https://example.com/push.git")
        #expect(try await repository.pushURL(ofRemote: "origin") == "https://example.com/push.git")
        try await repository.setPushURL(nil, ofRemote: "origin")
        #expect(try local.git("remote", "get-url", "--push", "origin") == remote.path)
        #expect(try await repository.pushURL(ofRemote: "origin") == nil)
        // Clearing one that is not set is no error.
        try await repository.setPushURL("", ofRemote: "origin")
    }

    // MARK: Fetch options

    @Test func fetchTagsAllOrNone() async throws {
        defer { remove() }
        // A tag on a commit no branch on the remote holds: only `--tags` brings it.
        try otherGit("commit", "--quiet", "--allow-empty", "-m", "Tagged only")
        try otherGit("tag", "loose")
        try otherGit("push", "--quiet", "origin", "loose")
        try otherGit("reset", "--quiet", "--hard", "HEAD~1")
        try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try otherGit("tag", "-a", "-m", "Release", "v1")
        try otherGit("push", "--quiet", "origin", "v1")
        try local.git("tag", "mine")

        // No tags at all, in a copy of the repository.
        let untagged = try twin()
        defer { try? FileManager.default.removeItem(at: untagged) }
        try await Repository(at: untagged).fetch(remote: "origin", tags: .none)
        #expect(try Fixture.run(["tag", "--list"], in: untagged) == "mine")

        // The usual fetch follows `remote.<name>.tagOpt`, as git's does…
        let configured = untagged.appendingPathExtension("configured")
        defer { try? FileManager.default.removeItem(at: configured) }
        try FileManager.default.copyItem(at: local.url, to: configured)
        _ = try Fixture.run(["config", "remote.origin.tagOpt", "--no-tags"], in: configured)
        try await Repository(at: configured).fetch(remote: "origin", tags: .automatic)
        #expect(try Fixture.run(["tag", "--list"], in: configured) == "mine")

        // …and without one brings every tag. git would leave out `loose`,
        // whose commit no branch holds, but libgit2 asks for all tags.
        let repository = try local.open()
        try await repository.fetch(remote: "origin", tags: .automatic)
        #expect(try local.git("tag", "--list").split(separator: "\n") == ["loose", "mine", "v1"])

        let gitFetched = untagged.appendingPathExtension("git")
        defer { try? FileManager.default.removeItem(at: gitFetched) }
        try FileManager.default.copyItem(at: local.url, to: gitFetched)
        try await repository.fetch(remote: "origin", prune: true, tags: .all)
        _ = try Fixture.run(["fetch", "--quiet", "--tags", "origin"], in: gitFetched)
        #expect(try local.git("tag", "--list") == Fixture.run(["tag", "--list"], in: gitFetched))
        // Pruning removes remote branches, never local tags.
        #expect(try local.git("tag", "--list").split(separator: "\n") == ["loose", "mine", "v1"])
    }

    // MARK: Pull modes

    @Test func pullByRebasingReplaysLocalCommitsAsGitDoes() async throws {
        defer { remove() }
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try local.commit("c.txt", "mine\n", message: "Mine")
        try local.commit("d.txt", "more\n", message: "More")
        let twin = try twin()
        defer { try? FileManager.default.removeItem(at: twin) }
        _ = try Fixture.run(["pull", "--quiet", "--rebase"], in: twin)

        let outcome = try await local.open().pull(options: PullOptions(mode: .rebase))

        #expect(outcome.result == .rebased(onto: OID(hex: theirs)!))
        #expect(outcome.autostash == .notNeeded)
        let shape = ["log", "--format=%s %T %an", "--first-parent"]
        #expect(try local.git(shape[0], shape[1], shape[2]) == Fixture.run(shape, in: twin))
        #expect(try local.git("rev-parse", "HEAD~2") == theirs)
        #expect(try local.git("symbolic-ref", "HEAD") == "refs/heads/main")
        #expect(try local.git("status", "--porcelain").isEmpty)
    }

    @Test func pullByRebasingStopsOnConflicts() async throws {
        defer { remove() }
        try otherCommitAndPush("a.txt", "theirs\n", message: "Their change")
        try local.commit("a.txt", "mine\n", message: "My change")

        let outcome = try await local.open().pull(options: PullOptions(mode: .rebase))

        guard case .rebaseStopped(_, let conflicts) = outcome.result else {
            Issue.record("Expected the rebase to stop, got \(outcome.result)")
            return
        }
        #expect(conflicts == ["a.txt"])
        #expect(try await local.open().snapshot().state == .rebasing)
        try await local.open().abortOperation()
        #expect(try read("a.txt") == "mine\n")
    }

    @Test func fastForwardOnlyRefusesDivergedHistoryLikeGit() async throws {
        defer { remove() }
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        let mine = try local.commit("c.txt", "mine\n", message: "Mine")
        let twin = try twin()
        defer { try? FileManager.default.removeItem(at: twin) }
        #expect(throws: FixtureError.self) { try Fixture.run(["pull", "--quiet", "--ff-only"], in: twin) }

        await #expect(throws: RemoteError.cannotFastForward(branch: "main", onto: "origin/main")) {
            try await local.open().pull(options: PullOptions(mode: .fastForwardOnly))
        }
        #expect(try local.git("rev-parse", "HEAD") == mine)
        // The fetch still happened, as it does for git.
        #expect(try local.git("rev-parse", "origin/main") == theirs)
    }

    @Test func fastForwardOnlyMovesForward() async throws {
        defer { remove() }
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        let outcome = try await local.open().pull(options: PullOptions(mode: .fastForwardOnly))
        #expect(outcome.result == .fastForwarded(to: OID(hex: theirs)!))
        #expect(try local.git("reflog", "-1", "--format=%gs") == "pull: Fast-forward")
    }

    @Test func pullFollowsTheConfiguredMode() async throws {
        defer { remove() }
        let repository = try local.open()
        #expect(await repository.configuredPullMode() == nil)
        try local.git("config", "pull.rebase", "true")
        #expect(await repository.configuredPullMode() == .rebase)
        try local.git("config", "branch.main.rebase", "false")
        #expect(await repository.configuredPullMode() == .merge)
        #expect(await repository.configuredPullMode(for: "refs/heads/other") == .rebase)
        // As in git, fast-forward only comes before rebasing.
        try local.git("config", "pull.ff", "only")
        #expect(await repository.configuredPullMode() == .fastForwardOnly)
        try local.git("config", "--unset", "pull.ff")
        try local.git("config", "--unset", "branch.main.rebase")

        // With no mode given, the configuration decides: here, a rebase.
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try local.commit("c.txt", "mine\n", message: "Mine")
        #expect(try await repository.pull() == .rebased(onto: OID(hex: theirs)!))
        #expect(try local.git("rev-list", "--merges", "--count", "HEAD") == "0")
    }

    @Test func pullFromAnotherRemoteBranch() async throws {
        defer { remove() }
        try otherGit("checkout", "--quiet", "-b", "feature")
        try "feature\n".write(to: other.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try otherGit("add", "f.txt")
        try otherGit("commit", "--quiet", "-m", "Feature")
        try otherGit("push", "--quiet", "origin", "feature")
        let feature = try otherGit("rev-parse", "HEAD")
        let mine = try local.commit("c.txt", "mine\n", message: "Mine")

        let outcome = try await local.open().pull(
            from: "refs/remotes/origin/feature", options: PullOptions(mode: .merge)
        )

        guard case .merged = outcome.result else {
            Issue.record("Expected a merge, got \(outcome.result)")
            return
        }
        #expect(try local.git("rev-parse", "HEAD^1") == mine)
        #expect(try local.git("rev-parse", "HEAD^2") == feature)
        #expect(try local.git("log", "-1", "--format=%s") == "Merge branch 'feature' of \(remote.path)")
        #expect(try local.git("symbolic-ref", "HEAD") == "refs/heads/main")
    }

    // MARK: Autostash

    @Test func autostashLetsARebasePullRunAndRestoresTheChanges() async throws {
        defer { remove() }
        try local.commit("c.txt", "mine\n", message: "Mine")
        try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try local.write("changed\n", to: "a.txt")
        try local.write("staged\n", to: "c.txt")
        try local.git("add", "c.txt")
        try local.write("untracked\n", to: "u.txt")

        // Without it the rebase refuses, as git's does.
        await #expect(throws: GitError.self) {
            try await local.open().pull(options: PullOptions(mode: .rebase))
        }
        #expect(try local.git("stash", "list").isEmpty)

        let outcome = try await local.open().pull(options: PullOptions(mode: .rebase, autostash: true))

        #expect(outcome.autostash == .restored)
        guard case .rebased = outcome.result else {
            Issue.record("Expected a rebase, got \(outcome.result)")
            return
        }
        let status = try local.git("status", "--porcelain").split(separator: "\n")
        // Staged changes come back staged. (The fixture trims the first line's leading space.)
        #expect(status == ["M a.txt", "M  c.txt", "?? u.txt"])
        #expect(try read("a.txt") == "changed\n")
        #expect(try local.git("stash", "list").isEmpty)
    }

    @Test func autostashKeepsTheStashWhenRestoringConflicts() async throws {
        defer { remove() }
        try otherCommitAndPush("a.txt", "theirs\n", message: "Their change")
        try local.write("mine\n", to: "a.txt")

        // A fast-forward that would overwrite the change: blocked without autostash.
        await #expect(throws: GitError.self) { try await local.open().pull() }

        let outcome = try await local.open().pull(options: PullOptions(autostash: true))

        guard case .conflicted(let stash, let paths) = outcome.autostash else {
            Issue.record("Expected a conflicting restore, got \(outcome.autostash)")
            return
        }
        #expect(paths == ["a.txt"])
        #expect(try local.git("rev-parse", "stash@{0}") == stash.hex)
        #expect(try local.git("status", "--porcelain") == "UU a.txt")
        #expect(try read("a.txt").contains("<<<<<<<"))
    }

    @Test func autostashWaitsWhenThePullStopsOnConflicts() async throws {
        defer { remove() }
        try otherCommitAndPush("a.txt", "theirs\n", message: "Their change")
        try local.commit("a.txt", "mine\n", message: "My change")
        try local.commit("c.txt", "c\n", message: "C")
        try local.write("changed\n", to: "c.txt")

        let outcome = try await local.open().pull(options: PullOptions(mode: .merge, autostash: true))

        #expect(outcome.result == .conflicts(paths: ["a.txt"]))
        guard case .keptForLater(let stash) = outcome.autostash else {
            Issue.record("Expected the stash kept for later, got \(outcome.autostash)")
            return
        }
        #expect(try local.git("rev-parse", "stash@{0}") == stash.hex)
        #expect(try read("c.txt") == "c\n")
    }

    @Test func autostashWithoutChangesStashesNothing() async throws {
        defer { remove() }
        try local.write("untracked\n", to: "u.txt")
        let repository = try local.open()
        let result = try await repository.withAutostash { repository in
            try repository.checkOut(branch: "refs/heads/main")
            return 1
        }
        #expect(result.value == 1 && result.autostash == .notNeeded)
        #expect(try local.git("stash", "list").isEmpty)
    }

    @Test func autostashPutsChangesBackWhenTheOperationFails() async throws {
        defer { remove() }
        try local.write("changed\n", to: "a.txt")
        let repository = try local.open()
        await #expect(throws: GitError.self) {
            try await repository.withAutostash { repository in
                try repository.checkOut(branch: "refs/heads/nowhere")
            }
        }
        #expect(try local.git("status", "--porcelain") == "M a.txt")
        #expect(try local.git("stash", "list").isEmpty)
    }

    @Test func autostashAroundACheckoutCarriesChangesAcross() async throws {
        defer { remove() }
        try local.git("checkout", "--quiet", "-b", "topic")
        try local.commit("a.txt", "topic\n", message: "Topic")
        try local.git("checkout", "--quiet", "main")
        try local.write("one\nmore\n", to: "a.txt")
        let repository = try local.open()

        do {
            try await repository.checkOut(branch: "refs/heads/topic")
            Issue.record("The checkout should be blocked by the change")
        } catch let error as GitError {
            #expect(error.isBlockedByLocalChanges)
        }

        let result = try await repository.withAutostash { try $0.checkOut(branch: "refs/heads/topic") }
        #expect(try local.git("symbolic-ref", "HEAD") == "refs/heads/topic")
        if case .conflicted = result.autostash {} else {
            Issue.record("Both changed a.txt, so restoring conflicts: got \(result.autostash)")
        }
    }

    // MARK: Sync

    @Test func syncPullsThenPushes() async throws {
        defer { remove() }
        let theirs = try otherCommitAndPush("b.txt", "other\n", message: "Other work")
        try local.commit("c.txt", "mine\n", message: "Mine")

        let transfer = Transfer()
        let reports = Task { await transfer.progress.reduce(into: []) { $0.append($1) } }
        let result = try await local.open().sync(options: PullOptions(mode: .rebase), transfer: transfer)

        #expect(result.push == PushResult(remote: "origin", reference: "refs/heads/main", setUpstream: false))
        #expect(try remoteGit("rev-parse", "main") == local.git("rev-parse", "HEAD"))
        #expect(try local.git("rev-parse", "HEAD~1") == theirs)
        let phases = await reports.value.map(\.phase)
        #expect(phases.contains(.sendingObjects) || phases.contains(.countingObjects))
    }

    @Test func syncStoppedOnConflictsPushesNothing() async throws {
        defer { remove() }
        let theirs = try otherCommitAndPush("a.txt", "theirs\n", message: "Their change")
        try local.commit("a.txt", "mine\n", message: "My change")
        let result = try await local.open().sync(options: PullOptions(mode: .merge))
        #expect(result.pull.result == .conflicts(paths: ["a.txt"]))
        #expect(result.push == nil)
        #expect(try remoteGit("rev-parse", "main") == theirs)
    }

    // MARK: Push to…

    @Test func pushAnyBranchToAChosenNameAndTrackIt() async throws {
        defer { remove() }
        try local.git("branch", "topic")
        try local.git("checkout", "--quiet", "topic")
        let topic = try local.commit("t.txt", "t\n", message: "Topic")
        try local.git("checkout", "--quiet", "main")

        let repository = try local.open()
        let result = try await repository.push(
            branch: "refs/heads/topic", to: "origin", as: "review/topic", setUpstream: true
        )
        #expect(result == PushResult(remote: "origin", reference: "refs/heads/review/topic", setUpstream: true))
        #expect(try remoteGit("rev-parse", "review/topic") == topic)
        #expect(try local.git("rev-parse", "--abbrev-ref", "topic@{upstream}") == "origin/review/topic")
        // HEAD stayed where it was.
        #expect(try local.git("symbolic-ref", "HEAD") == "refs/heads/main")

        try await repository.push(branch: "refs/heads/main", to: "origin", as: "copy")
        #expect(try remoteGit("rev-parse", "copy") == local.git("rev-parse", "main"))
        #expect(try local.git("rev-parse", "--abbrev-ref", "main@{upstream}") == "origin/main")
    }

    // MARK: Tags on a remote

    @Test func publishPushAllAndDeleteTags() async throws {
        defer { remove() }
        try local.git("tag", "v1")
        try local.git("tag", "-a", "-m", "Two", "v2")
        try local.git("tag", "v3")
        let repository = try local.open()

        try await repository.pushTags(["refs/tags/v1"], to: "origin")
        #expect(try remoteGit("tag", "--list") == "v1")

        let count = try await repository.pushAllTags(to: "origin")
        #expect(count == 3)
        #expect(try remoteGit("tag", "--list").split(separator: "\n") == ["v1", "v2", "v3"])
        #expect(try remoteGit("rev-parse", "v2") == local.git("rev-parse", "v2"))

        try await repository.deleteRemoteTag("refs/tags/v3", on: "origin")
        #expect(try remoteGit("tag", "--list").split(separator: "\n") == ["v1", "v2"])
        // The local tag stays.
        #expect(try local.git("tag", "--list").contains("v3"))
    }

    @Test func pushingATagTheRemoteHasElsewhereIsRefused() async throws {
        defer { remove() }
        try otherGit("tag", "v1")
        try otherGit("push", "--quiet", "origin", "v1")
        try local.commit("a.txt", "two\n", message: "Second")
        try local.git("tag", "v1")
        await #expect(throws: RemoteError.tagExistsOnRemote("v1")) {
            try await local.open().pushTags(["v1"], to: "origin")
        }
        #expect(try remoteGit("rev-parse", "v1") == otherGit("rev-parse", "v1"))
    }

    // MARK: Branches on a remote

    @Test func deleteARemoteBranch() async throws {
        defer { remove() }
        try local.git("push", "--quiet", "origin", "main:old")
        try local.git("fetch", "--quiet", "origin")

        try await local.open().deleteRemoteBranch("refs/remotes/origin/old")

        #expect(try remoteGit("branch", "--list").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } == ["* main"])
        #expect(try !local.git("branch", "-r").contains("origin/old"))
    }

    @Test func renameARemoteBranchMovesTrackingBranchesWithIt() async throws {
        defer { remove() }
        try local.git("checkout", "--quiet", "-b", "topic")
        let topic = try local.commit("t.txt", "t\n", message: "Topic")
        try local.git("push", "--quiet", "-u", "origin", "topic")

        let renamed = try await local.open().renameRemoteBranch("refs/remotes/origin/topic", to: "feature/topic")

        #expect(renamed == "refs/remotes/origin/feature/topic")
        #expect(try remoteGit("rev-parse", "feature/topic") == topic)
        #expect(throws: FixtureError.self) { try remoteGit("rev-parse", "--verify", "--quiet", "refs/heads/topic") }
        #expect(try local.git("rev-parse", "--abbrev-ref", "topic@{upstream}") == "origin/feature/topic")
        #expect(try !local.git("branch", "-r").contains("origin/topic\n"))
        let snapshot = try await local.open().snapshot()
        #expect(snapshot.branches.first { $0.name == "topic" }?.upstream?.name == "origin/feature/topic")
    }
}
