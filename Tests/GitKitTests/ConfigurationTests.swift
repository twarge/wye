import Foundation
import GitKit
import Testing

@Suite struct ConfigurationTests {
    /// `git config --local --list`, as entries.
    private func gitEntries(_ fixture: Fixture) throws -> [ConfigurationEntry] {
        try fixture.git("config", "--local", "--list").split(separator: "\n").map { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return ConfigurationEntry(name: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    @Test func listsTheLocalConfigurationAsGitDoes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.git("config", "--add", "Remote.Upstream.fetch", "+refs/heads/a:refs/remotes/upstream/a")
        try fixture.git("config", "--add", "remote.Upstream.fetch", "+refs/heads/b:refs/remotes/upstream/b")
        try fixture.git("config", "core.autocrlf", "input")
        let repository = try fixture.open()
        #expect(try await repository.configurationEntries(at: .local) == gitEntries(fixture))
        #expect(try await repository.configurationValues("remote.Upstream.fetch") == [
            "+refs/heads/a:refs/remotes/upstream/a", "+refs/heads/b:refs/remotes/upstream/b"
        ])
        #expect(try await repository.configurationValue("CORE.autocrlf") == "input")
    }

    @Test func writesSingleAndMultipleValuesThatGitReads() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.open()

        try await repository.setConfigurationValue("true", for: "twigtest.flag")
        #expect(try fixture.git("config", "--local", "--get", "twigtest.flag") == "true")

        try await repository.setConfigurationValues(["one", "two", "two", "three"], for: "twigtest.Section.list")
        #expect(try fixture.git("config", "--local", "--get-all", "twigtest.Section.list") == "one\ntwo\ntwo\nthree")

        // Replacing one of several values keeps the others in order.
        try await repository.setConfigurationValues(["one", "2", "two", "three"], for: "twigtest.Section.list")
        #expect(try fixture.git("config", "--local", "--get-all", "twigtest.Section.list") == "one\n2\ntwo\nthree")

        try await repository.removeConfiguration("twigtest.Section.list")
        #expect(throws: FixtureError.self) { try fixture.git("config", "--local", "--get-all", "twigtest.Section.list") }

        // Values git would have to quote come back as they went in.
        let awkward = "a value; with # comment \"quotes\" and \\ backslash"
        try await repository.setConfigurationValue(awkward, for: "twigtest.awkward")
        #expect(try fixture.git("config", "--local", "--get", "twigtest.awkward") == awkward)
        try await repository.setConfigurationValues([awkward, "tab\there", "plain"], for: "twigtest.awkwardlist")
        #expect(try fixture.git("config", "--local", "--get-all", "twigtest.awkwardlist") == "\(awkward)\ntab\there\nplain")
        #expect(try await repository.configurationValues("twigtest.awkwardlist") == [awkward, "tab\there", "plain"])
        #expect(try await repository.configurationEntries(at: .local) == gitEntries(fixture))
    }

    @Test(arguments: [
        ("core.editor", "core.editor"),
        ("Core.Editor", "core.editor"),
        ("remote.My Copy.url", "remote.My Copy.url"),
        ("Branch.Topic/Thing.Merge", "branch.Topic/Thing.merge")
    ])
    func normalizesKeysAsGitDoes(_ key: String, _ expected: String) throws {
        #expect(try Repository.normalizedConfigurationName(key) == expected)
    }

    @Test(arguments: ["core", ".editor", "core.", "core.1editor", "co re.editor", "core.edi_tor"])
    func refusesKeysGitRefuses(_ key: String) async throws {
        #expect(throws: ConfigurationError.self) { try Repository.normalizedConfigurationName(key) }
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: FixtureError.self) { try fixture.git("config", "--local", key, "x") }
    }

    @Test func setsTheRepositoryAuthor() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.open()
        try await repository.setLocalIdentity(GitIdentity(name: "Repo Author", email: "repo@example.com"))
        #expect(try fixture.git("config", "--local", "user.name") == "Repo Author")
        #expect(try fixture.git("config", "--local", "user.email") == "repo@example.com")
        let identity = try await repository.localIdentity()
        #expect(identity.name == "Repo Author" && identity.email == "repo@example.com")

        try await repository.setLocalIdentity(nil)
        #expect(throws: FixtureError.self) { try fixture.git("config", "--local", "user.name") }
    }

    @Test func writesThePullModeGitReads() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.open()

        try await repository.setConfiguredPullMode(.rebase)
        #expect(try fixture.git("config", "--local", "pull.rebase") == "true")
        #expect(await repository.configuredPullMode() == .rebase)

        try await repository.setConfiguredPullMode(.fastForwardOnly)
        #expect(try fixture.git("config", "--local", "pull.ff") == "only")
        #expect(throws: FixtureError.self) { try fixture.git("config", "--local", "pull.rebase") }
        #expect(await repository.configuredPullMode() == .fastForwardOnly)

        try await repository.setConfiguredPullMode(.merge)
        #expect(try fixture.git("config", "--local", "pull.rebase") == "false")
        #expect(await repository.configuredPullMode() == .merge)

        try await repository.setConfiguredPullMode(nil)
        #expect(throws: FixtureError.self) { try fixture.git("config", "--local", "pull.rebase") }
        #expect(await repository.configuredPullMode() == nil)
    }

    // MARK: Remotes

    /// A repository with `origin`, fetched, whose branches are `main` and `topic`.
    private func fixtureWithRemote() throws -> (local: Fixture, remote: Fixture) {
        let remote = try Fixture()
        try remote.commit("a.txt", "a\n", message: "One")
        try remote.git("branch", "topic")
        let local = try Fixture()
        try local.git("remote", "add", "origin", remote.url.path)
        try local.git("fetch", "--quiet", "origin")
        return (local, remote)
    }

    @Test func editsRefspecsAsGitConfigShowsThem() async throws {
        let (local, remote) = try fixtureWithRemote()
        defer { local.remove(); remote.remove() }
        let repository = try local.open()
        #expect(try await repository.refspecs(ofRemote: "origin", direction: .fetch) == ["+refs/heads/*:refs/remotes/origin/*"])
        #expect(try await repository.refspecs(ofRemote: "origin", direction: .push).isEmpty)

        let fetch = ["+refs/heads/main:refs/remotes/origin/main", "+refs/heads/topic:refs/remotes/origin/topic"]
        try await repository.setRefspecs(fetch, ofRemote: "origin", direction: .fetch)
        try await repository.setRefspecs(["refs/heads/main:refs/heads/main"], ofRemote: "origin", direction: .push)
        #expect(try local.git("config", "--get-all", "remote.origin.fetch") == fetch.joined(separator: "\n"))
        #expect(try local.git("config", "--get-all", "remote.origin.push") == "refs/heads/main:refs/heads/main")
        #expect(try await repository.refspecs(ofRemote: "origin", direction: .fetch) == fetch)

        // git fetches by the new refspecs.
        try remote.git("branch", "other")
        try await repository.fetch(remote: "origin", prune: false)
        #expect(throws: FixtureError.self) { try local.git("rev-parse", "--verify", "--quiet", "refs/remotes/origin/other") }

        try await repository.setRefspecs([], ofRemote: "origin", direction: .push)
        #expect(throws: FixtureError.self) { try local.git("config", "--get-all", "remote.origin.push") }
    }

    @Test func refusesRefspecsGitCannotRead() async throws {
        let (local, remote) = try fixtureWithRemote()
        defer { local.remove(); remote.remove() }
        let repository = try local.open()
        await #expect(throws: ConfigurationError.invalidRefspec("refs/heads/a b:refs/x")) {
            try await repository.setRefspecs(["refs/heads/a b:refs/x"], ofRemote: "origin", direction: .fetch)
        }
        #expect(try local.git("config", "--get-all", "remote.origin.fetch") == "+refs/heads/*:refs/remotes/origin/*")
        #expect(Repository.isValidRefspec("+refs/heads/*:refs/remotes/origin/*", direction: .fetch))
        #expect(Repository.isValidRefspec("refs/heads/main", direction: .push))
        #expect(!Repository.isValidRefspec("", direction: .fetch))
        #expect(!Repository.isValidRefspec("refs/heads/*:refs/remotes/origin/main", direction: .fetch))
        await #expect(throws: RemoteError.remoteNotFound("nowhere")) {
            try await repository.refspecs(ofRemote: "nowhere", direction: .fetch)
        }
    }

    @Test func setsTheRemoteDefaultBranchAsSetHeadDoes() async throws {
        let (local, remote) = try fixtureWithRemote()
        defer { local.remove(); remote.remove() }
        let repository = try local.open()
        // Recent versions of git record it on the first fetch; start without.
        try local.git("remote", "set-head", "origin", "--delete")
        #expect(try await repository.defaultBranch(ofRemote: "origin") == nil)

        try local.git("remote", "set-head", "origin", "main")
        #expect(try await repository.defaultBranch(ofRemote: "origin") == "main")

        try await repository.setDefaultBranch("topic", ofRemote: "origin")
        #expect(try local.git("symbolic-ref", "refs/remotes/origin/HEAD") == "refs/remotes/origin/topic")

        await #expect(throws: ConfigurationError.remoteBranchNotFetched(remote: "origin", branch: "missing")) {
            try await repository.setDefaultBranch("missing", ofRemote: "origin")
        }

        try await repository.setDefaultBranch(nil, ofRemote: "origin")
        #expect(throws: FixtureError.self) { try local.git("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD") }
    }

    // MARK: New repositories

    @Test func createsARepositoryOnTheInitialBranchWithItsFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "GitKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let empty = folder.appending(path: "empty")
        let repository = try await Repository.create(at: empty, options: NewRepositoryOptions(initialBranch: "trunk"))
        #expect(repository.url == empty)
        #expect(try Fixture.run(["symbolic-ref", "HEAD"], in: empty) == "refs/heads/trunk")
        #expect(throws: FixtureError.self) { try Fixture.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: empty) }
        // Not over a repository that is already there.
        await #expect(throws: (any Error).self) {
            try await Repository.create(at: empty, options: NewRepositoryOptions(initialBranch: "trunk"))
        }

        // The files are written; committing them waits for an author, which
        // the test leaves to the repository's own configuration.
        let withFiles = folder.appending(path: "with files")
        let created = try await Repository.create(at: withFiles, options: NewRepositoryOptions(
            initialBranch: "feature/start", files: ["README.md": "# Project\n", ".gitignore": ".DS_Store\n"], commitFiles: false
        ))
        #expect(try Fixture.run(["symbolic-ref", "HEAD"], in: withFiles) == "refs/heads/feature/start")
        #expect(try Fixture.run(["status", "--porcelain"], in: withFiles) == "?? .gitignore\n?? README.md")
        try await created.setLocalIdentity(GitIdentity(name: "Test Author", email: "author@example.com"))
        try await created.stage([".gitignore", "README.md"])
        try await created.commit(message: "Initial commit")
        #expect(try Fixture.run(["show", "HEAD:README.md"], in: withFiles) == "# Project")

        await #expect(throws: (any Error).self) {
            try await Repository.create(at: folder.appending(path: "bad"), options: NewRepositoryOptions(initialBranch: "bad..name"))
        }
        #expect(!Repository.isValidBranchName("bad..name"))
        #expect(Repository.isValidBranchName("feature/one"))
    }
}
