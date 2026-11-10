import Foundation
import GitKit
import Testing

/// Moving files and restoring them from a commit, compared with what git
/// itself does to the same repository.
@Suite struct FileOperationTests {
    let fixture: Fixture
    let twin: Fixture

    init() throws {
        fixture = try Fixture()
        twin = try Fixture()
    }

    private func removeBoth() {
        fixture.remove()
        twin.remove()
    }

    /// The index and the status, which together say what git sees.
    private func state(of fixture: Fixture) throws -> String {
        try fixture.git("ls-files", "--stage") + "\n--\n"
            + fixture.git("status", "--porcelain", "--untracked-files=all")
    }

    @Test func movesATrackedFileAsGitMvDoes() async throws {
        defer { removeBoth() }
        for fixture in [fixture, twin] {
            try fixture.commit("old/name.txt", "one\n", message: "First")
            try fixture.commit("other.txt", "x\n", message: "Second")
            // A staged change and an unstaged one on top, which the move keeps apart.
            try fixture.write("two\n", to: "old/name.txt")
            try fixture.git("add", "old/name.txt")
            try fixture.write("three\n", to: "old/name.txt")
        }
        try await fixture.open().move("old/name.txt", to: "new/place/renamed.txt")
        try twin.git("mv", "old/name.txt", "renamed.txt")
        try FileManager.default.createDirectory(at: twin.url.appending(path: "new/place"), withIntermediateDirectories: true)
        try twin.git("mv", "renamed.txt", "new/place/renamed.txt")

        #expect(try state(of: fixture) == state(of: twin))
        #expect(try fixture.indexContent(of: "new/place/renamed.txt", is: "two\n"))
        #expect(try fixture.workingContent(of: "new/place/renamed.txt") == "three\n")
        // The emptied folder goes, as with git.
        #expect(!FileManager.default.fileExists(atPath: fixture.url.appending(path: "old").path))
    }

    @Test func movesAnUntrackedFileOnDiskOnly() async throws {
        defer { removeBoth() }
        try fixture.commit("a.txt", "a\n", message: "First")
        try fixture.write("draft\n", to: "draft.txt")
        try await fixture.open().move("draft.txt", to: "notes/draft.md")
        #expect(try fixture.git("status", "--porcelain", "--untracked-files=all") == "?? notes/draft.md")
    }

    @Test func refusesToMoveOntoSomethingOrOutside() async throws {
        defer { removeBoth() }
        try fixture.commit("a.txt", "a\n", message: "First")
        try fixture.commit("b.txt", "b\n", message: "Second")
        let repository = try fixture.open()
        await #expect(throws: FileOperationError.destinationExists("b.txt")) {
            try await repository.move("a.txt", to: "b.txt")
        }
        for path in ["../a.txt", "x/../../a.txt", ".git/a.txt", "", "/"] {
            await #expect(throws: FileOperationError.self, "\(path)") {
                try await repository.move("a.txt", to: path)
            }
        }
        await #expect(throws: FileOperationError.sourceMissing("missing.txt")) {
            try await repository.move("missing.txt", to: "c.txt")
        }
        #expect(try fixture.git("status", "--porcelain") == "")
    }

    @Test func changesOnlyTheCaseOfAName() async throws {
        defer { removeBoth() }
        try fixture.commit("readme.md", "x\n", message: "First")
        try await fixture.open().move("readme.md", to: "README.md")
        #expect(try fixture.git("ls-files") == "README.md")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).contains("README.md"))
    }

    @Test func restoresAFileFromAnEarlierCommitAsGitRestoreDoes() async throws {
        defer { removeBoth() }
        var first = ""
        for fixture in [fixture, twin] {
            first = try fixture.commit("file.txt", "version one\n", message: "First")
            try fixture.commit("file.txt", "version two\n", message: "Second")
            try fixture.write("staged\n", to: "file.txt")
            try fixture.git("add", "file.txt")
            try fixture.write("local edit\n", to: "file.txt")
        }
        let repository = try fixture.open()
        #expect(try await repository.hasUncommittedChanges(at: "file.txt"))
        let firstID = try await repository.resolveRevision(try fixture.git("rev-parse", "HEAD~1"))
        try await repository.restore("file.txt", from: firstID)
        try twin.git("restore", "--source=\(first)", "--", "file.txt")

        #expect(try fixture.workingContent(of: "file.txt") == "version one\n")
        #expect(try state(of: fixture) == state(of: twin))
        // What was staged stays staged.
        #expect(try fixture.indexContent(of: "file.txt", is: "staged\n"))
    }

    @Test func restoresADeletedFileAndItsMode() async throws {
        defer { removeBoth() }
        try fixture.write("#!/bin/sh\n", to: "run.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.url.appending(path: "run.sh").path)
        try fixture.git("add", "run.sh")
        try fixture.git("commit", "--quiet", "-m", "Script")
        try fixture.git("rm", "--quiet", "run.sh")
        try fixture.git("commit", "--quiet", "-m", "Remove")
        let repository = try fixture.open()
        #expect(try await !repository.hasUncommittedChanges(at: "run.sh"))
        let id = try await repository.resolveRevision("HEAD~1")
        try await repository.restore("run.sh", from: id)
        #expect(try fixture.git("status", "--porcelain") == "?? run.sh")
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.appending(path: "run.sh").path)
        #expect((attributes[.posixPermissions] as? Int ?? 0) & 0o100 != 0)

        await #expect(throws: FileOperationError.notInRevision("nothing.txt")) {
            try await repository.restore("nothing.txt", from: id)
        }
    }
}
