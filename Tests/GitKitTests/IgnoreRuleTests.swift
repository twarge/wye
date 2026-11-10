import Foundation
import GitKit
import Testing

/// Writing ignore rules, stopping tracking and "assume unchanged", checked
/// against what git itself then reports.
@Suite struct IgnoreRuleTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    /// Whether git's own `check-ignore` says the rules match a path.
    private func gitIgnores(_ path: String) -> Bool {
        // check-ignore exits with 1 when nothing matches.
        (try? fixture.git("check-ignore", "--no-index", "--quiet", path)) != nil
    }

    @Test func patternsMatchWhatTheyNameAndNothingElse() async throws {
        defer { fixture.remove() }
        try fixture.commit("README.md", "x\n", message: "First")
        let names = [
            "notes.txt", "docs/notes.txt", "a*b.txt", "a?b.txt", "x[1].txt", "#hash.txt", "!bang.txt",
            "trailing .txt", "sp ace/file.txt", "deep/er/file.log", "back\\slash.txt"
        ]
        for name in names { try fixture.write("x\n", to: name) }
        // Look-alikes that a careless pattern would also catch.
        for name in ["aXb.txt", "x1.txt", "other/notes.txt", "deep/er/file.log.bak"] {
            try fixture.write("x\n", to: name)
        }
        let repository = try fixture.open()

        try await repository.addIgnorePatterns([
            IgnorePattern.file("notes.txt"), IgnorePattern.file("a*b.txt"), IgnorePattern.file("a?b.txt"),
            IgnorePattern.file("x[1].txt"), IgnorePattern.file("#hash.txt"), IgnorePattern.file("!bang.txt"),
            IgnorePattern.file("trailing .txt"), IgnorePattern.folder("sp ace"),
            IgnorePattern.file("back\\slash.txt"), try #require(IgnorePattern.fileExtension(of: "deep/er/file.log"))
        ], to: .shared)

        for path in [
            "notes.txt", "a*b.txt", "a?b.txt", "x[1].txt", "#hash.txt", "!bang.txt", "trailing .txt",
            "sp ace/file.txt", "deep/er/file.log", "back\\slash.txt"
        ] {
            #expect(gitIgnores(path), "\(path)")
        }
        for path in ["docs/notes.txt", "other/notes.txt", "aXb.txt", "x1.txt", "deep/er/file.log.bak", "README.md"] {
            #expect(!gitIgnores(path), "\(path)")
        }
        // GitKit reads the rules the same way.
        for path in names + ["aXb.txt", "x1.txt", "other/notes.txt", "deep/er/file.log.bak"] {
            #expect(try await repository.isIgnored(path) == gitIgnores(path), "\(path)")
        }
    }

    @Test func extensionPatterns() {
        #expect(IgnorePattern.fileExtension(of: "a/b/c.log") == "*.log")
        #expect(IgnorePattern.fileExtension(of: "archive.tar.gz") == "*.gz")
        #expect(IgnorePattern.fileExtension(of: ".env") == nil)
        #expect(IgnorePattern.fileExtension(of: "Makefile") == nil)
        #expect(IgnorePattern.fileExtension(of: "trailingdot.") == nil)
        #expect(IgnorePattern.extensionName(of: "a/b.swift") == ".swift")
        #expect(IgnorePattern.folder("build/") == "/build/")
    }

    @Test func createsAndEditsTheSharedAndLocalFiles() async throws {
        defer { fixture.remove() }
        try fixture.commit("README.md", "x\n", message: "First")
        try fixture.write("x", to: "build/out.o")
        try fixture.write("x", to: "local.txt")
        let repository = try fixture.open()

        try await repository.addIgnorePatterns(["/build/", "/build/"], to: .shared)
        try await repository.addIgnorePatterns(["/local.txt"], to: .local)
        #expect(try String(contentsOf: fixture.url.appending(path: ".gitignore"), encoding: .utf8) == "/build/\n")
        #expect(try fixture.git("status", "--porcelain") == "?? .gitignore")
        #expect(try await repository.ignorePatterns(in: .shared) == ["/build/"])
        #expect(try await repository.ignorePatterns(in: .local) == ["/local.txt"])

        // Comments and other rules survive edits, and a file without a final
        // newline is extended properly.
        try "# keep me\n*.tmp\n/build/".write(to: fixture.url.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try await repository.addIgnorePatterns(["*.bak"], to: .shared)
        #expect(try String(contentsOf: fixture.url.appending(path: ".gitignore"), encoding: .utf8)
            == "# keep me\n*.tmp\n/build/\n*.bak\n")
        try await repository.removeIgnorePatterns(["/build/"], from: .shared)
        #expect(try await repository.ignorePatterns(in: .shared) == ["*.tmp", "*.bak"])
        #expect(gitIgnores("x.bak") && !gitIgnores("build/out.o"))
        #expect(try fixture.git("status", "--porcelain", "--untracked-files=all")
            == "?? .gitignore\n?? build/out.o")
    }

    @Test func listsIgnoredPathsAsGitStatusDoes() async throws {
        defer { fixture.remove() }
        try fixture.commit(".gitignore", "build/\n*.log\n", message: "Ignore")
        try fixture.write("x", to: "build/a/b.o")
        try fixture.write("x", to: "build/c.o")
        try fixture.write("x", to: "debug.log")
        try fixture.write("x", to: "src/trace.log")
        try fixture.write("x", to: "src/main.c")
        try fixture.write("x", to: "kept.log")
        try fixture.git("add", "--force", "kept.log")
        try fixture.git("commit", "--quiet", "-m", "Tracked log")
        let ignored = try await fixture.open().ignoredPaths()
        let expected = try fixture.git("status", "--porcelain", "--ignored")
            .split(separator: "\n").filter { $0.hasPrefix("!! ") }.map { String($0.dropFirst(3)) }
        #expect(ignored == expected)
        #expect(ignored.contains("build/"))
    }

    @Test func findsTrackedFilesTheRulesMatch() async throws {
        defer { fixture.remove() }
        try fixture.commit("app.log", "x", message: "Log")
        try fixture.commit("src/a.c", "x", message: "Source")
        try fixture.write("*.log\n", to: ".gitignore")
        let repository = try fixture.open()
        #expect(try await repository.trackedIgnoredPaths() == ["app.log"])
        #expect(try await repository.isTracked("src"))
        #expect(try await repository.isTracked("app.log"))
        #expect(try await !repository.isTracked("missing"))
    }

    @Test func stopsTrackingAsGitRmCachedDoes() async throws {
        let twin = try Fixture()
        defer {
            fixture.remove()
            twin.remove()
        }
        for fixture in [fixture, twin] {
            try fixture.commit("keep.txt", "keep\n", message: "One")
            try fixture.commit("secret.env", "token\n", message: "Two")
            try fixture.commit("build/a.o", "a\n", message: "Three")
            try fixture.commit("build/sub/b.o", "b\n", message: "Four")
            try fixture.write("changed\n", to: "secret.env")
        }
        try await fixture.open().stopTracking(["secret.env", "build/"])
        try twin.git("rm", "--cached", "--quiet", "secret.env")
        try twin.git("rm", "-r", "--cached", "--quiet", "build")

        #expect(try fixture.git("status", "--porcelain", "--untracked-files=all")
            == twin.git("status", "--porcelain", "--untracked-files=all"))
        #expect(try fixture.git("ls-files", "--stage") == twin.git("ls-files", "--stage"))
        // The files stay on disk as they were.
        #expect(try fixture.workingContent(of: "secret.env") == "changed\n")
        #expect(FileManager.default.fileExists(atPath: fixture.url.appending(path: "build/sub/b.o").path))
    }

    @Test func setsAndClearsAssumeUnchanged() async throws {
        defer { fixture.remove() }
        try fixture.commit("config.json", "{}\n", message: "One")
        try fixture.commit("other.txt", "x\n", message: "Two")
        let repository = try fixture.open()

        try await repository.setAssumeUnchanged(true, for: ["config.json"])
        // git marks such a file with a lowercase letter.
        #expect(try fixture.git("ls-files", "-v") == "h config.json\nH other.txt")
        #expect(try await repository.assumeUnchangedPaths() == ["config.json"])

        try fixture.write("{\"local\": true}\n", to: "config.json")
        #expect(try fixture.git("status", "--porcelain") == "")
        #expect(try await repository.status().isEmpty)

        try await repository.setAssumeUnchanged(false, for: ["config.json"])
        #expect(try fixture.git("ls-files", "-v") == "H config.json\nH other.txt")
        #expect(try fixture.git("status", "--porcelain") == "M config.json")
        #expect(try await repository.assumeUnchangedPaths().isEmpty)

        // And git's own flag is read back.
        try fixture.git("update-index", "--assume-unchanged", "other.txt")
        #expect(try await repository.assumeUnchangedPaths() == ["other.txt"])
    }
}
