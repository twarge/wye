import Foundation
import GitKit
import Testing

/// Pruning a remote without fetching, and pushing a chosen commit to a
/// chosen remote branch, against a bare repository on disk.
@Suite struct RemotePruneTests {
    let local: Fixture
    let remote: URL

    init() throws {
        local = try Fixture()
        try local.commit("a.txt", "one\n", message: "First")
        remote = local.url.appendingPathExtension("remote.git")
        try local.git("clone", "--quiet", "--bare", ".", remote.path)
        try local.git("remote", "add", "origin", remote.path)
        try remoteGit("branch", "old", "main")
        try remoteGit("branch", "older", "main")
        try local.git("fetch", "--quiet", "origin")
    }

    private func remove() {
        local.remove()
        try? FileManager.default.removeItem(at: remote)
    }

    @discardableResult
    private func remoteGit(_ arguments: String...) throws -> String {
        try Fixture.run(arguments, in: remote)
    }

    private func remoteBranches() throws -> [String] {
        try local.git("for-each-ref", "--format=%(refname)", "refs/remotes").split(separator: "\n").map(String.init)
    }

    // MARK: Prune

    @Test func pruneRemovesWhatGitRemotePruneRemovesAndFetchesNothing() async throws {
        defer { remove() }
        try remoteGit("branch", "-D", "old", "older")
        // New work on the remote, which a prune must not bring.
        let before = try local.git("rev-parse", "origin/main")
        try local.git("commit", "--quiet", "--allow-empty", "-m", "Elsewhere")
        try local.git("push", "--quiet", "origin", "HEAD:refs/heads/main")
        try local.git("update-ref", "refs/remotes/origin/main", before)
        try local.git("reset", "--quiet", "--hard", "HEAD~1")

        let dryRun = try local.git("remote", "prune", "--dry-run", "origin")
        let pruned = try await local.open().pruneRemote("origin")

        #expect(pruned == ["refs/remotes/origin/old", "refs/remotes/origin/older"])
        #expect(dryRun.contains("origin/old") && dryRun.contains("origin/older"))
        // `origin/HEAD` is from the command line fetch in `init`.
        #expect(try remoteBranches() == ["refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        #expect(try local.git("rev-parse", "origin/main") == before)
    }

    @Test func pruningWhenNothingIsGoneChangesNothing() async throws {
        defer { remove() }
        let branches = try remoteBranches()
        #expect(try await local.open().pruneRemote("origin").isEmpty)
        #expect(try remoteBranches() == branches)
    }

    @Test func pruningAnUnknownRemoteFails() async throws {
        defer { remove() }
        await #expect(throws: RemoteError.remoteNotFound("nowhere")) {
            try await local.open().pruneRemote("nowhere")
        }
    }

    // MARK: Pushing a commit

    @Test func pushesACommitToANewBranch() async throws {
        defer { remove() }
        let first = try local.git("rev-parse", "HEAD")
        try local.commit("b.txt", "two\n", message: "Second")
        let repository = try local.open()
        let id = try #require(OID(hex: first))
        #expect(try await repository.pushWouldFastForward(id, to: "origin", as: "fresh"))

        let result = try await repository.push(commit: id, to: "origin", as: "fresh")
        #expect(result.reference == "refs/heads/fresh")
        #expect(try remoteGit("rev-parse", "refs/heads/fresh") == first)
        // Nothing local moved.
        #expect(try local.git("rev-parse", "--abbrev-ref", "HEAD") == "main")
    }

    @Test func aPushThatDropsCommitsIsRefusedUnlessForced() async throws {
        defer { remove() }
        let first = try local.git("rev-parse", "HEAD")
        try local.commit("b.txt", "two\n", message: "Second")
        try local.git("push", "--quiet", "origin", "main")
        try local.git("fetch", "--quiet", "origin")
        let repository = try local.open()
        let id = try #require(OID(hex: first))

        #expect(try await repository.pushWouldFastForward(id, to: "origin", as: "main") == false)
        await #expect(throws: (any Error).self) {
            try await repository.push(commit: id, to: "origin", as: "main")
        }
        #expect(try remoteGit("rev-parse", "refs/heads/main") == local.git("rev-parse", "HEAD"))

        try await repository.push(commit: id, to: "origin", as: "main", force: true)
        #expect(try remoteGit("rev-parse", "refs/heads/main") == first)
    }

    @Test func aForcedPushIsRefusedWhenTheRemoteMovedSinceTheLastFetch() async throws {
        defer { remove() }
        let first = try local.git("rev-parse", "HEAD")
        try local.commit("b.txt", "two\n", message: "Second")
        try local.git("push", "--quiet", "origin", "main")
        try local.git("fetch", "--quiet", "origin")
        // Someone else pushes again, unseen here.
        let other = local.url.appendingPathExtension("other")
        defer { try? FileManager.default.removeItem(at: other) }
        try local.git("clone", "--quiet", remote.path, other.path)
        _ = try Fixture.run(["-c", "user.name=O", "-c", "user.email=o@example.com", "commit", "--quiet",
                         "--allow-empty", "-m", "Unseen"], in: other)
        _ = try Fixture.run(["push", "--quiet", "origin", "main"], in: other)
        let unseen = try remoteGit("rev-parse", "refs/heads/main")

        let id = try #require(OID(hex: first))
        await #expect(throws: (any Error).self) {
            try await local.open().push(commit: id, to: "origin", as: "main", force: true)
        }
        #expect(try remoteGit("rev-parse", "refs/heads/main") == unseen)
    }

    @Test func aBranchNameMustBeValid() async throws {
        defer { remove() }
        let id = try #require(OID(hex: try local.git("rev-parse", "HEAD")))
        await #expect(throws: BranchingError.self) {
            try await local.open().push(commit: id, to: "origin", as: "bad..name")
        }
    }
}
