import Foundation
import GitKit
import Testing

/// Pushing a branch with every tag along, checked against
/// `git push --tags <remote> <branch>`.
@Suite struct PushTagsTests {
    /// The repository GitKit works in, with `main` tracking `origin/main`.
    let local: Fixture
    /// The bare repository standing as `origin`, which GitKit pushes to.
    let remote: URL
    /// A second bare copy, `mirror`, which the command line git pushes to.
    let mirror: URL
    /// Another clone of `origin`, standing for someone else's work.
    let other: URL

    init() throws {
        local = try Fixture()
        try local.commit("a.txt", "one\n", message: "First")
        remote = local.url.appendingPathExtension("remote.git")
        mirror = local.url.appendingPathExtension("mirror.git")
        other = local.url.appendingPathExtension("other")
        try local.git("clone", "--quiet", "--bare", ".", remote.path)
        try local.git("clone", "--quiet", "--bare", ".", mirror.path)
        try local.git("remote", "add", "origin", remote.path)
        try local.git("remote", "add", "mirror", mirror.path)
        try local.git("fetch", "--quiet", "origin")
        try local.git("fetch", "--quiet", "mirror")
        try local.git("branch", "--set-upstream-to=origin/main")
        try local.git("clone", "--quiet", remote.path, other.path)
        try Fixture.run(["config", "user.name", "Other Author"], in: other)
        try Fixture.run(["config", "user.email", "other@example.com"], in: other)
    }

    private func remove() {
        local.remove()
        for url in [remote, mirror, other] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    private func remoteGit(_ arguments: String...) throws -> String {
        try Fixture.run(arguments, in: remote)
    }

    @discardableResult
    private func otherGit(_ arguments: String...) throws -> String {
        try Fixture.run(arguments, in: other)
    }

    /// A bare repository's branches and tags, with what each points at.
    private func references(in repository: URL) throws -> String {
        try Fixture.run(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags"], in: repository)
    }

    /// Someone else tags the first commit `v1` and pushes the tag to
    /// `origin`; here `v1` goes on a new commit.
    private func makeConflictingV1() throws -> String {
        try otherGit("tag", "v1")
        try otherGit("push", "--quiet", "origin", "v1")
        try local.commit("a.txt", "two\n", message: "Second")
        try local.git("tag", "v1")
        return try otherGit("rev-parse", "v1")
    }

    @Test func pushingWithTagsLeavesWhatGitLeaves() async throws {
        defer { remove() }
        try local.git("tag", "light")
        try local.commit("a.txt", "two\n", message: "Second")
        try local.git("tag", "-a", "-m", "Release one", "v1")
        // A tag on a commit no pushed branch holds goes too, as with --tags.
        try local.git("checkout", "--quiet", "-b", "side")
        try local.commit("s.txt", "s\n", message: "Side")
        try local.git("tag", "-a", "-m", "Side release", "side-tag")
        try local.git("checkout", "--quiet", "main")

        let result = try await local.open().push(includingTags: true)
        try local.git("push", "--quiet", "--tags", "mirror", "main")

        #expect(try references(in: remote) == references(in: mirror))
        #expect(try remoteGit("rev-parse", "main") == local.git("rev-parse", "main"))
        // The annotated tag arrives as the same tag object, message and all.
        #expect(try remoteGit("rev-parse", "v1") == local.git("rev-parse", "v1"))
        #expect(try remoteGit("cat-file", "-t", "v1") == "tag")
        #expect(result.tags == PushedTags(pushed: ["light", "side-tag", "v1"], rejected: []))
        // The side branch itself stays here.
        #expect(throws: FixtureError.self) { try remoteGit("rev-parse", "--verify", "--quiet", "refs/heads/side") }
    }

    @Test func tagsTheRemoteHasAlreadyAreLeftAlone() async throws {
        defer { remove() }
        try local.git("tag", "v1")
        try local.git("push", "--quiet", "origin", "v1")
        try local.commit("a.txt", "two\n", message: "Second")
        try local.git("tag", "-a", "-m", "Two", "v2")

        let repository = try local.open()
        let first = try await repository.push(includingTags: true)
        #expect(first.tags == PushedTags(pushed: ["v2"], rejected: []))
        let again = try await repository.push(includingTags: true)
        #expect(again.tags == PushedTags(pushed: [], rejected: []))
        #expect(try remoteGit("tag", "--list").split(separator: "\n") == ["v1", "v2"])
    }

    @Test func aTagTheRemoteHasElsewhereIsNotOverwrittenAndTheBranchStillGoes() async throws {
        defer { remove() }
        let theirs = try makeConflictingV1()
        try local.git("tag", "v2")

        let result = try await local.open().push(includingTags: true)

        #expect(try remoteGit("rev-parse", "main") == local.git("rev-parse", "main"))
        #expect(try remoteGit("rev-parse", "v1") == theirs)
        #expect(try remoteGit("rev-parse", "v2") == local.git("rev-parse", "v2"))
        #expect(result.tags == PushedTags(
            pushed: ["v2"], rejected: [.init(tag: "v1", reason: PushedTags.elsewhereReason)]
        ))

        // git does the same: the branch and v2 land, v1 is turned down.
        try Fixture.run(["tag", "-f", "v1", theirs], in: mirror)
        #expect(throws: FixtureError.self) { try local.git("push", "--quiet", "--tags", "mirror", "main") }
        #expect(try references(in: remote) == references(in: mirror))
    }

    @Test func aForcePushNeverForcesTags() async throws {
        defer { remove() }
        let theirs = try makeConflictingV1()
        try local.git("push", "--quiet", "origin", "main")
        // Rewrite the pushed commit, so the branch needs forcing.
        try local.git("commit", "--quiet", "--amend", "-m", "Second, reworded")
        try local.git("tag", "v3")

        let result = try await local.open().push(force: true, includingTags: true)

        #expect(try remoteGit("rev-parse", "main") == local.git("rev-parse", "main"))
        #expect(try remoteGit("rev-parse", "v1") == theirs)
        #expect(result.tags?.rejected.map(\.tag) == ["v1"])
        #expect(result.tags?.pushed == ["v3"])
    }

    @Test func nothingButTheBranchGoesWithoutTags() async throws {
        defer { remove() }
        try local.commit("a.txt", "two\n", message: "Second")
        try local.git("tag", "v1")
        try local.git("tag", "-a", "-m", "Two", "v2")

        let result = try await local.open().push()

        #expect(result.tags == nil)
        #expect(try remoteGit("rev-parse", "main") == local.git("rev-parse", "main"))
        #expect(try remoteGit("tag", "--list") == "")
    }

    @Test func pushingToABranchElsewhereAndSyncingTakeTagsToo() async throws {
        defer { remove() }
        try local.git("tag", "v1")
        let repository = try local.open()
        let pushed = try await repository.push(
            branch: "refs/heads/main", to: "mirror", as: "copy", includingTags: true
        )
        #expect(pushed.tags?.pushed == ["v1"])
        #expect(try Fixture.run(["tag", "--list"], in: mirror) == "v1")

        try local.commit("a.txt", "two\n", message: "Second")
        try local.git("tag", "v2")
        let synced = try await repository.sync(options: PullOptions(), includingTags: true)
        #expect(synced.push?.tags?.pushed.sorted() == ["v1", "v2"])
        #expect(try remoteGit("tag", "--list").split(separator: "\n") == ["v1", "v2"])
    }

    @Test func aNewTagReachesTheRemotesThatAnswer() async throws {
        defer { remove() }
        try local.git("remote", "add", "gone", local.url.appendingPathExtension("missing.git").path)
        let repository = try local.open()
        let tag = try await repository.createTag(named: "v1", at: OID(hex: local.git("rev-parse", "HEAD"))!)

        var failed: [String] = []
        for name in ["gone", "origin", "mirror"] {
            do {
                try await repository.pushTags([tag], to: name)
            } catch {
                failed.append(name)
            }
        }
        #expect(failed == ["gone"])
        #expect(try remoteGit("tag", "--list") == "v1")
        #expect(try Fixture.run(["tag", "--list"], in: mirror) == "v1")
    }
}
