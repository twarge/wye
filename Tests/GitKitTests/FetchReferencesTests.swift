import Foundation
import GitKit
import Testing

/// Fetching chosen refspecs, as checking out a pull request does, from a
/// remote by name and from a URL that is no remote, compared with git.
@Suite struct FetchReferencesTests {
    let local: Fixture
    /// The bare repository standing as `origin`, with a pull request's
    /// head under `refs/pull/7/head` as the services keep them.
    let remote: URL
    /// Someone else's copy, with the head branch.
    let contributor: URL

    init() throws {
        local = try Fixture()
        try local.commit("a.txt", "one\n", message: "First")
        remote = local.url.appendingPathExtension("remote.git")
        contributor = local.url.appendingPathExtension("contributor.git")
        try local.git("clone", "--quiet", "--bare", ".", remote.path)
        try local.git("remote", "add", "origin", remote.path)
        try local.git("fetch", "--quiet", "origin")
        try local.git("clone", "--quiet", "--bare", ".", contributor.path)
    }

    private func remove() {
        local.remove()
        try? FileManager.default.removeItem(at: remote)
        try? FileManager.default.removeItem(at: contributor)
    }

    /// Makes a commit on a branch elsewhere and pushes it to `destination`
    /// as `reference`, leaving the local repository without it.
    private func pushCommit(to destination: URL, as reference: String) throws -> String {
        try local.git("checkout", "--quiet", "-b", "scratch")
        let commit = try local.commit("b.txt", "two\n", message: "Second")
        try local.git("push", "--quiet", destination.path, "HEAD:\(reference)")
        try local.git("checkout", "--quiet", "main")
        try local.git("branch", "--quiet", "-D", "scratch")
        try local.git("reflog", "expire", "--expire-unreachable=now", "--all")
        try local.git("gc", "--quiet", "--prune=now")
        return commit
    }

    @Test func fetchesAPullRequestReferenceFromARemote() async throws {
        defer { remove() }
        let commit = try pushCommit(to: remote, as: "refs/pull/7/head")
        let repository = try local.open()
        #expect(await !repository.hasCommit(try #require(OID(hex: commit))))

        try await repository.fetch(refspecs: ["+refs/pull/7/head:refs/remotes/origin/pr/7"], from: "origin")
        #expect(try local.git("rev-parse", "refs/remotes/origin/pr/7") == commit)
        #expect(await repository.hasCommit(try #require(OID(hex: commit))))
    }

    @Test func fetchesFromAURLThatIsNoRemote() async throws {
        defer { remove() }
        let commit = try pushCommit(to: contributor, as: "refs/heads/topic")
        let repository = try local.open()
        let url = "file://" + contributor.path
        try await repository.fetch(refspecs: ["+refs/heads/topic:refs/remotes/mona/topic"], from: url)
        #expect(try local.git("rev-parse", "refs/remotes/mona/topic") == commit)
        // No remote was configured for it.
        #expect(try local.git("remote") == "origin")
    }

    @Test func refspecWithoutDestinationKeepsOnlyTheCommits() async throws {
        defer { remove() }
        let commit = try pushCommit(to: remote, as: "refs/pull/8/head")
        let repository = try local.open()
        let before = try local.git("for-each-ref", "--format=%(refname)")
        try await repository.fetch(refspecs: ["refs/pull/8/head"], from: "origin")
        #expect(await repository.hasCommit(try #require(OID(hex: commit))))
        #expect(try local.git("for-each-ref", "--format=%(refname)") == before)
    }

    @Test func unknownRemoteNameIsSaidSo() async throws {
        defer { remove() }
        let repository = try local.open()
        await #expect(throws: RemoteError.remoteNotFound("nowhere")) {
            try await repository.fetch(refspecs: ["refs/heads/main"], from: "nowhere")
        }
    }

    @Test func mergeBaseMatchesGit() async throws {
        defer { remove() }
        let base = try local.git("rev-parse", "HEAD")
        try local.git("checkout", "--quiet", "-b", "topic")
        let topic = try local.commit("t.txt", "t\n", message: "Topic")
        try local.git("checkout", "--quiet", "main")
        let main = try local.commit("m.txt", "m\n", message: "Main")
        let repository = try local.open()
        let found = try await repository.mergeBase(try #require(OID(hex: main)), try #require(OID(hex: topic)))
        #expect(found.hex == base)
        #expect(try local.git("merge-base", main, topic) == base)
    }
}
