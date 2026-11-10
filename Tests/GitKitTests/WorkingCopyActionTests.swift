import Foundation
import GitKit
import Testing

/// Discarding, amending and resolving conflicts.
@Suite struct WorkingCopyActionTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    @Test func discardsTrackedAndUntrackedChanges() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.commit("b.txt", "one\n", message: "Second")
        try fixture.commit("c.txt", "one\n", message: "Third")
        try fixture.write("staged\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("staged then edited\n", to: "a.txt")
        try fixture.write("edited\n", to: "b.txt")
        try FileManager.default.removeItem(at: fixture.url.appending(path: "c.txt"))
        try fixture.write("new\n", to: "folder/deep/new.txt")

        let repository = try fixture.open()
        try await repository.discardChanges(in: ["a.txt", "b.txt", "c.txt", "folder/deep/new.txt"], untracked: .delete)

        // Staged changes stay; everything unstaged is gone.
        #expect(try fixture.git("status", "--porcelain") == "M  a.txt")
        #expect(try fixture.workingContent(of: "a.txt") == "staged\n")
        #expect(try fixture.workingContent(of: "b.txt") == "one\n")
        #expect(try fixture.workingContent(of: "c.txt") == "one\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.url.appending(path: "folder").path))
    }

    @Test func discardsEverything() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.write("edited\n", to: "a.txt")
        try fixture.write("new\n", to: "new.txt")
        let repository = try fixture.open()
        try await repository.discardAllChanges(untracked: .delete)
        #expect(try fixture.git("status", "--porcelain").isEmpty)
    }

    @Test func discardingEveryLineOfANewFileRemovesIt() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.write("new\n", to: "new.txt")
        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "new.txt"))
        try await repository.discard(lines: diff.changedLineIDs, of: diff, untracked: .delete)
        #expect(try fixture.git("status", "--porcelain").isEmpty)
    }

    @Test func amendsTheMessageAndContent() async throws {
        defer { fixture.remove() }
        let first = try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.commit("b.txt", "one\n", message: "Second\n\nWith a body.")
        let repository = try fixture.open()
        #expect(try await repository.lastCommitMessage() == "Second\n\nWith a body.\n")

        // The message alone.
        var id = try await repository.amend(message: "Second, reworded")
        #expect(try fixture.git("rev-parse", "HEAD") == id.hex)
        #expect(try fixture.git("log", "--format=%s", "-2") == "Second, reworded\nFirst")
        #expect(try fixture.git("rev-parse", "HEAD^") == first)
        #expect(try fixture.git("show", "--format=", "--name-only", "HEAD") == "b.txt")

        // With a staged change.
        try fixture.write("two\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        id = try await repository.amend(message: "Second, with more")
        #expect(try fixture.git("rev-parse", "HEAD") == id.hex)
        #expect(try fixture.git("show", "--format=", "--name-only", "HEAD") == "a.txt\nb.txt")
        #expect(try fixture.git("log", "--format=%an <%ae>", "-1") == "Test Author <author@example.com>")
        #expect(try fixture.git("status", "--porcelain").isEmpty)
        #expect(try fixture.git("rev-list", "--count", "HEAD") == "2")
    }

    @Test func refusesToAmendNothing() async throws {
        defer { fixture.remove() }
        let repository = try fixture.open()
        #expect(try await repository.lastCommitMessage() == nil)
        await #expect(throws: WorkingCopyError.nothingToAmend) { try await repository.amend(message: "x") }
    }

    /// Two branches that change the same line, merged into a conflict.
    private func conflict() throws {
        try fixture.commit("a.txt", "base\n", message: "Base")
        try fixture.commit("gone.txt", "base\n", message: "Base 2")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        try fixture.write("topic\n", to: "a.txt")
        try fixture.write("topic\n", to: "gone.txt")
        try fixture.git("commit", "--quiet", "-am", "Topic")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.write("main\n", to: "a.txt")
        try fixture.git("rm", "--quiet", "gone.txt")
        try fixture.git("commit", "--quiet", "-am", "Main")
        #expect(throws: (any Error).self) { try fixture.git("merge", "topic") }
    }

    @Test(arguments: [ConflictSide.ours, .theirs])
    func resolvesWithOneSide(side: ConflictSide) async throws {
        defer { fixture.remove() }
        try conflict()
        let repository = try fixture.open()
        #expect(try await repository.status().filter(\.isConflicted).map(\.path) == ["a.txt", "gone.txt"])

        try await repository.resolveConflict(at: "a.txt", using: side)
        try await repository.resolveConflict(at: "gone.txt", using: side)
        let expected = side == .ours ? "main\n" : "topic\n"
        #expect(try fixture.workingContent(of: "a.txt") == expected)
        #expect(try fixture.indexContent(of: "a.txt", is: expected))
        #expect(try fixture.git("diff", "--name-only", "--diff-filter=U").isEmpty)
        if side == .ours {
            // Ours is HEAD, and deleted the other file, which stays deleted.
            #expect(try fixture.git("status", "--porcelain").isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.url.appending(path: "gone.txt").path))
        } else {
            #expect(try fixture.git("status", "--porcelain") == "M  a.txt\nA  gone.txt")
        }
        #expect(try await repository.snapshot().state == .merging)
        await #expect(throws: WorkingCopyError.notConflicted(path: "a.txt")) {
            try await repository.resolveConflict(at: "a.txt", using: side)
        }
    }

    @Test func marksAnEditedFileResolved() async throws {
        defer { fixture.remove() }
        try conflict()
        let repository = try fixture.open()
        try fixture.write("both\n", to: "a.txt")
        try await repository.markResolved(["a.txt"])
        #expect(try fixture.git("diff", "--name-only", "--diff-filter=U") == "gone.txt")
        #expect(try fixture.indexContent(of: "a.txt", is: "both\n"))
        await #expect(throws: WorkingCopyError.conflicted(path: "gone.txt")) {
            try await repository.discardChanges(in: ["gone.txt"], untracked: .delete)
        }
    }
}
