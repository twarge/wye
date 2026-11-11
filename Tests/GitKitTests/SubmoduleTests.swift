import Foundation
@testable import GitKit
import Testing

/// Submodules, compared with what the command line git does and reports.
@Suite struct SubmoduleTests {
    /// The first column of `git submodule status`: ` ` up to date, `-` not
    /// initialized, `+` at another commit, then the checked-out commit.
    private func statusLines(_ fixture: Fixture, recursive: Bool = false) throws -> [String] {
        let output = recursive
            ? try fixture.git("submodule", "status", "--recursive")
            : try fixture.git("submodule", "status")
        return output.split(separator: "\n").map { line in
            // The fixture trims the output, taking the first line's leading space.
            let line = line.first?.isHexDigit == true ? " " + line : String(line)
            // Leave out the description in brackets, which varies.
            return line.split(separator: " ", omittingEmptySubsequences: false).prefix(3).joined(separator: " ")
        }
    }

    /// A superproject with one submodule `lib`, pushed to a bare
    /// `super.git`, and a fresh clone of that without its submodules.
    private func publishedSuperproject(_ fixture: SubmoduleFixture) throws -> (bare: URL, clone: Fixture) {
        let lib = try fixture.makeLibrary("lib")
        try fixture.main.submoduleGit("submodule", "--quiet", "add", lib.path, "lib")
        try fixture.main.git("commit", "--quiet", "-m", "Add lib")
        let bare = fixture.folder.appending(path: "super.git")
        try fixture.main.git("clone", "--quiet", "--bare", ".", bare.path)
        return (bare, try fixture.clone(bare, as: "fresh"))
    }

    @Test func initializesAndUpdatesAFreshClone() async throws {
        let fixture = try SubmoduleFixture()
        defer { fixture.remove() }
        let (_, fresh) = try publishedSuperproject(fixture)
        let repository = try fresh.open()

        var listed = try #require(try await repository.submodules().first)
        #expect(listed.path == "lib")
        #expect(listed.status == .notInitialized)
        #expect(try statusLines(fresh).first?.hasPrefix("-") == true)

        try await repository.initializeSubmodules()
        listed = try #require(try await repository.submodules().first)
        #expect(listed.status == .notCloned)
        #expect(try fresh.git("config", "submodule.lib.url") == fixture.folder.appending(path: "lib.git").path)

        try await repository.updateSubmodules()
        listed = try #require(try await repository.submodules().first)
        #expect(listed.status == .upToDate)
        let recorded = try fresh.git("ls-files", "-s", "lib").split(separator: " ")[1]
        #expect(listed.recordedID?.hex == String(recorded))
        #expect(listed.checkedOutID?.hex == String(recorded))
        #expect(try statusLines(fresh) == [" \(recorded) lib"])
        // The submodule opens as a repository of its own, through its `.git` file.
        let inner = try await repository.openSubmodule("lib")
        #expect(try await inner.head().target?.hex == String(recorded))
        #expect(!fresh.fileExists("lib/.git/HEAD"))
    }

    @Test func updatesNestedSubmodulesRecursively() async throws {
        let fixture = try SubmoduleFixture()
        defer { fixture.remove() }
        let deep = try fixture.makeLibrary("deep")
        let lib = try fixture.makeLibrary("lib")
        let libWork = try fixture.libraryWork("lib")
        try libWork.submoduleGit("submodule", "--quiet", "add", deep.path, "deep")
        try libWork.git("commit", "--quiet", "-m", "Add deep")
        try libWork.git("push", "--quiet", lib.path, "main")
        try fixture.main.submoduleGit("submodule", "--quiet", "add", lib.path, "lib")
        try fixture.main.git("commit", "--quiet", "-m", "Add lib")
        let fresh = try fixture.clone(fixture.main.url, as: "fresh")

        try await fresh.open().updateSubmodules(recursive: true)
        let lines = try statusLines(fresh, recursive: true)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.hasPrefix(" ") })
        #expect(fresh.fileExists("lib/deep/file.txt"))
        // git agrees nothing is left to do.
        try fresh.submoduleGit("submodule", "--quiet", "update", "--init", "--recursive")
        #expect(try statusLines(fresh, recursive: true) == lines)
    }

    @Test func addsASubmoduleAsGitDoes() async throws {
        let fixture = try SubmoduleFixture()
        defer { fixture.remove() }
        let lib = try fixture.makeLibrary("lib", commits: ["One", "Two", "Three"])
        try fixture.libraryWork("lib").git("push", "--quiet", lib.path, "main:refs/heads/stable")
        let twin = try fixture.clone(fixture.main.url, as: "twin")

        let transfer = Transfer()
        let reports = Task { await transfer.progress.reduce(into: []) { $0.append($1.phase) } }
        let name = try await fixture.main.open().addSubmodule(
            url: lib.path, path: "vendor/lib", branch: "stable", transfer: transfer
        )
        #expect(name == "vendor/lib")
        // The stream keeps only the newest report, so which ones arrive varies.
        #expect(await !reports.value.isEmpty)
        try twin.submoduleGit("submodule", "--quiet", "add", "-b", "stable", lib.path, "vendor/lib")

        #expect(try fixture.main.git("config", "-f", ".gitmodules", "--list") == twin.git("config", "-f", ".gitmodules", "--list"))
        #expect(try fixture.main.git("ls-files", "-s") == twin.git("ls-files", "-s"))
        #expect(try fixture.main.git("diff", "--cached", "--name-status") == twin.git("diff", "--cached", "--name-status"))
        #expect(try statusLines(fixture.main) == statusLines(twin))
        let inner = Fixture(existing: fixture.main.url.appending(path: "vendor/lib"))
        #expect(try inner.git("rev-parse", "--abbrev-ref", "HEAD") == "stable")
        #expect(try inner.git("rev-parse", "--abbrev-ref", "@{upstream}") == "origin/stable")
        #expect(fixture.main.fileExists(".git/modules/vendor/lib/HEAD"))
    }

    @Test func recordsARelativeURLAndClonesWhatItResolvesTo() async throws {
        let fixture = try SubmoduleFixture()
        defer { fixture.remove() }
        try fixture.makeLibrary("lib")
        let superBare = fixture.folder.appending(path: "super.git")
        try fixture.main.git("clone", "--quiet", "--bare", ".", superBare.path)
        try fixture.main.git("remote", "add", "origin", superBare.path)
        try fixture.main.git("fetch", "--quiet", "origin")
        try fixture.main.git("branch", "--quiet", "--set-upstream-to=origin/main")

        let repository = try fixture.main.open()
        #expect(await repository.resolveSubmoduleURL("../lib.git") == fixture.folder.appending(path: "lib.git").path)
        try await repository.addSubmodule(url: "../lib.git", path: "lib")
        #expect(try fixture.main.git("config", "-f", ".gitmodules", "submodule.lib.url") == "../lib.git")
        try fixture.main.git("commit", "--quiet", "-m", "Add lib")
        try fixture.main.git("push", "--quiet", "origin", "main")

        // A clone elsewhere resolves it against its own origin, as git does.
        let ours = try fixture.clone(superBare, as: "ours")
        let theirs = try fixture.clone(superBare, as: "theirs")
        try await ours.open().updateSubmodules()
        try theirs.submoduleGit("submodule", "--quiet", "update", "--init")
        #expect(try ours.git("config", "submodule.lib.url") == theirs.git("config", "submodule.lib.url"))
        #expect(try statusLines(ours) == statusLines(theirs))
    }

    @Test func resolvesRelativeURLsAsGitDoes() {
        #expect(Repository.relativeURL("../other.git", base: "https://example.com/owner/project.git")
            == "https://example.com/owner/other.git")
        #expect(Repository.relativeURL("../../them/other.git", base: "https://example.com/owner/project.git/")
            == "https://example.com/them/other.git")
        #expect(Repository.relativeURL("./sub", base: "/srv/project.git") == "/srv/project.git/sub")
        #expect(Repository.relativeURL("../other.git", base: "git@example.com:owner/project.git")
            == "git@example.com:owner/other.git")
        #expect(Repository.relativeURL("../other.git", base: "git@example.com:project.git")
            == "git@example.com:other.git")
    }

    @Test func removesASubmoduleCompletely() async throws {
        let fixture = try SubmoduleFixture()
        defer { fixture.remove() }
        let lib = try fixture.makeLibrary("lib")
        let other = try fixture.makeLibrary("other")
        try fixture.main.submoduleGit("submodule", "--quiet", "add", lib.path, "lib")
        try fixture.main.submoduleGit("submodule", "--quiet", "add", other.path, "other")
        try fixture.main.git("commit", "--quiet", "-m", "Add both")
        let twin = try fixture.clone(fixture.main.url, as: "twin")
        try twin.submoduleGit("submodule", "--quiet", "update", "--init")

        let repository = try fixture.main.open()
        try fixture.main.write("changed\n", to: "lib/file.txt")
        await #expect(throws: SubmoduleError.hasLocalChanges("lib")) { try await repository.removeSubmodule("lib") }
        try await repository.removeSubmodule("lib", force: true)
        try twin.git("rm", "--quiet", "-f", "lib")

        #expect(try fixture.main.git("ls-files", "-s") == twin.git("ls-files", "-s"))
        #expect(try fixture.main.git("config", "-f", ".gitmodules", "--list") == twin.git("config", "-f", ".gitmodules", "--list"))
        #expect(try fixture.main.textOfFile(".gitmodules") == twin.textOfFile(".gitmodules"))
        #expect(try fixture.main.git("diff", "--cached", "--name-status") == twin.git("diff", "--cached", "--name-status"))
        #expect((try? fixture.main.git("config", "--get-regexp", "^submodule\\.lib\\.")) == nil)
        #expect(!fixture.main.fileExists("lib"))
        #expect(!fixture.main.fileExists(".git/modules/lib"))
        #expect(fixture.main.fileExists(".git/modules/other"))
        #expect(try statusLines(fixture.main).count == 1)
    }

    @Test func movesASubmoduleAsGitMvDoes() async throws {
        let fixture = try SubmoduleFixture()
        defer { fixture.remove() }
        let lib = try fixture.makeLibrary("lib")
        try fixture.main.submoduleGit("submodule", "--quiet", "add", lib.path, "lib")
        try fixture.main.git("commit", "--quiet", "-m", "Add lib")
        let twin = try fixture.clone(fixture.main.url, as: "twin")
        try twin.submoduleGit("submodule", "--quiet", "update", "--init")

        try await fixture.main.open().moveSubmodule("lib", to: "vendor/libs/lib")
        try FileManager.default.createDirectory(at: twin.url.appending(path: "vendor/libs"), withIntermediateDirectories: true)
        try twin.git("mv", "lib", "vendor/libs/lib")

        #expect(try fixture.main.git("ls-files", "-s") == twin.git("ls-files", "-s"))
        #expect(try fixture.main.git("config", "-f", ".gitmodules", "--list") == twin.git("config", "-f", ".gitmodules", "--list"))
        #expect(try fixture.main.git("diff", "--cached", "--name-status") == twin.git("diff", "--cached", "--name-status"))
        #expect(try statusLines(fixture.main) == statusLines(twin))
        let moved = Fixture(existing: fixture.main.url.appending(path: "vendor/libs/lib"))
        #expect(try moved.git("status", "--porcelain").isEmpty)
        #expect(try moved.git("rev-parse", "--show-toplevel").hasSuffix("vendor/libs/lib"))
        #expect(try fixture.main.git("config", "-f", ".git/modules/lib/config", "core.worktree")
            == twin.git("config", "-f", ".git/modules/lib/config", "core.worktree"))
        #expect(!fixture.main.fileExists("lib"))
    }

    @Test func synchronizesAndChangesURLs() async throws {
        let fixture = try SubmoduleFixture()
        defer { fixture.remove() }
        let lib = try fixture.makeLibrary("lib")
        try fixture.main.submoduleGit("submodule", "--quiet", "add", lib.path, "lib")
        try fixture.main.git("commit", "--quiet", "-m", "Add lib")
        let moved = fixture.folder.appending(path: "moved.git")
        try FileManager.default.copyItem(at: lib, to: moved)
        let twin = try fixture.clone(fixture.main.url, as: "twin")
        try twin.submoduleGit("submodule", "--quiet", "update", "--init")

        // Synchronize after someone else edited `.gitmodules`.
        for fixture in [fixture.main, twin] {
            try fixture.git("config", "-f", ".gitmodules", "submodule.lib.url", moved.path)
        }
        try await fixture.main.open().synchronizeSubmodules()
        try twin.git("submodule", "--quiet", "sync")
        #expect(try fixture.main.git("config", "submodule.lib.url") == moved.path)
        #expect(try fixture.main.git("-C", "lib", "config", "remote.origin.url") == twin.git("-C", "lib", "config", "remote.origin.url"))

        // Change URL: `.gitmodules`, staged, and the rest following.
        try await fixture.main.open().setSubmoduleURL("lib", to: lib.path)
        try twin.git("submodule", "--quiet", "set-url", "lib", lib.path)
        try twin.git("add", ".gitmodules")
        #expect(try fixture.main.git("config", "-f", ".gitmodules", "--list") == twin.git("config", "-f", ".gitmodules", "--list"))
        #expect(try fixture.main.git("diff", "--cached", "--name-status") == twin.git("diff", "--cached", "--name-status"))
        #expect(try fixture.main.git("config", "submodule.lib.url") == twin.git("config", "submodule.lib.url"))
        #expect(try fixture.main.git("-C", "lib", "config", "remote.origin.url") == lib.path)
    }

    @Test func reportsASubmoduleAheadOrBehindAndItsCommits() async throws {
        let fixture = try SubmoduleFixture()
        defer { fixture.remove() }
        let lib = try fixture.makeLibrary("lib", commits: ["One", "Two"])
        try fixture.main.submoduleGit("submodule", "--quiet", "add", lib.path, "lib")
        try fixture.main.git("commit", "--quiet", "-m", "Add lib")
        let inner = Fixture(existing: fixture.main.url.appending(path: "lib"))
        try inner.git("config", "user.name", "Test Author")
        try inner.git("config", "user.email", "author@example.com")
        let repository = try fixture.main.open()

        // Ahead: new commits inside, not yet recorded.
        try inner.commit("file.txt", "three\n", message: "Three")
        try inner.commit("file.txt", "four\n", message: "Four")
        var listed = try #require(try await repository.submodules().first)
        #expect(listed.status == .differentCommit)
        #expect(try statusLines(fixture.main).first?.hasPrefix("+") == true)
        var entry = try #require(try await repository.status().first { $0.path == "lib" })
        #expect(entry.submodule == .newCommits)
        var diff = try #require(try await repository.unstagedDiff(of: "lib"))
        var change = try #require(diff.submodule)
        #expect(diff.hunks.isEmpty)
        #expect(change.isAvailable)
        #expect(change.newID?.hex == (try inner.git("rev-parse", "HEAD")))
        #expect(gitLog(change) == (try submoduleLog(fixture.main)))
        #expect(change.commits.map(\.summary) == ["Four", "Three"])

        // Behind: checked out at an older commit than recorded.
        try await repository.checkOutSubmodule("lib", revision: "HEAD~3")
        listed = try #require(try await repository.submodules().first)
        #expect(listed.status == .differentCommit)
        diff = try #require(try await repository.unstagedDiff(of: "lib"))
        change = try #require(diff.submodule)
        #expect(change.commits.map(\.isAdded) == [false])
        #expect(gitLog(change) == (try submoduleLog(fixture.main)))

        // Back at the recorded commit, with content changed and untracked.
        try await repository.checkOutSubmodule("lib", revision: "main~2")
        try inner.write("edited\n", to: "file.txt")
        try inner.write("new\n", to: "untracked.txt")
        listed = try #require(try await repository.submodules().first)
        #expect(listed.status == .modifiedContent)
        entry = try #require(try await repository.status().first { $0.path == "lib" })
        #expect(entry.submodule == [.modifiedContent, .untrackedContent])
        diff = try #require(try await repository.unstagedDiff(of: "lib"))
        #expect(diff.submodule?.changes == [.modifiedContent, .untrackedContent])

        // A recorded change shows its range in the commit's diff.
        try FileManager.default.removeItem(at: inner.url.appending(path: "untracked.txt"))
        try inner.git("checkout", "--quiet", "--", ".")
        try inner.git("checkout", "--quiet", "main")
        try fixture.main.git("commit", "--quiet", "-am", "Move lib")
        let head = try #require(OID(hex: try fixture.main.git("rev-parse", "HEAD")))
        let committed = try #require(try await repository.changes(in: head).first { $0.path == "lib" })
        #expect(committed.submodule?.commits.map(\.summary) == ["Four", "Three"])
    }

    /// The lines of `git diff --submodule=log`, below its heading.
    private func submoduleLog(_ fixture: Fixture) throws -> [String] {
        try fixture.git("diff", "--submodule=log").split(separator: "\n").dropFirst().map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private func gitLog(_ change: SubmoduleChange) -> [String] {
        change.commits.map { "\($0.isAdded ? ">" : "<") \($0.summary)" }
    }

    @Test func cancellingAnAddLeavesNothingBehind() async throws {
        let fixture = try SubmoduleFixture()
        defer { fixture.remove() }
        // Enough objects that the clone reports progress before finishing.
        let work = try Fixture(at: fixture.folder.appending(path: "big-work"))
        for number in 0..<400 {
            try work.write(String(repeating: "\(UUID().uuidString)\n", count: 200), to: "files/\(number).txt")
        }
        // No automatic gc, which would repack in the background while the
        // objects are copied.
        try work.git("config", "gc.auto", "0")
        try work.git("config", "maintenance.auto", "false")
        try work.git("add", ".")
        try work.git("commit", "--quiet", "-m", "Many files")
        let bare = fixture.folder.appending(path: "big.git")
        try FileManager.default.copyItem(at: work.url.appending(path: ".git"), to: bare)
        _ = try Fixture.run(["config", "core.bare", "true"], in: bare)
        let before = try fixture.main.git("config", "--list", "--local")

        let transfer = Transfer()
        // Cancelled from the clone's own thread at its first object, as the
        // Cancel button would be, so the clone is surely under way.
        transfer.willReport = { [unowned transfer] progress in
            if progress.phase != .connecting { transfer.cancel() }
        }
        let repository = try fixture.main.open()
        await #expect(throws: CancellationError.self) {
            try await repository.addSubmodule(url: "file://" + bare.path, path: "big", transfer: transfer)
        }
        #expect(!fixture.main.fileExists(".gitmodules"))
        #expect(!fixture.main.fileExists("big"))
        #expect(!fixture.main.fileExists(".git/modules/big"))
        #expect(try fixture.main.git("config", "--list", "--local") == before)
        #expect(try fixture.main.git("status", "--porcelain").isEmpty)
    }
}
