import Foundation
import GitKit
import Testing

/// Snapshots, branching from a stash and a stash's patch, checked against git.
@Suite struct SnapshotTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.commit("b.txt", "bee\n", message: "Second")
    }

    /// Staged, unstaged and untracked changes all at once.
    private func makeChanges() throws {
        try fixture.write("one staged\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("one staged then edited\n", to: "a.txt")
        try fixture.write("bee edited\n", to: "b.txt")
        try fixture.write("new\n", to: "folder/new.txt")
    }

    @Test func aSnapshotKeepsTheChangesInPlaceAndAStash() async throws {
        defer { fixture.remove() }
        try makeChanges()
        let status = try fixture.git("status", "--porcelain", "--untracked-files=all")
        let staged = try fixture.git("diff", "--cached")
        let unstaged = try fixture.git("diff")

        let repository = try fixture.open()
        let id = try await repository.saveSnapshot(message: " Before refactoring ")

        // Everything is where it was, staged changes still staged.
        #expect(try fixture.git("status", "--porcelain", "--untracked-files=all") == status)
        #expect(try fixture.git("diff", "--cached") == staged)
        #expect(try fixture.git("diff") == unstaged)
        #expect(try fixture.textOfFile("folder/new.txt") == "new\n")

        // And git sees a stash holding all of it, untracked file included.
        #expect(try fixture.git("stash", "list", "--format=%gs") == "On main: Snapshot: Before refactoring")
        #expect(try fixture.git("rev-parse", "stash@{0}") == id.hex)
        #expect(try fixture.git("show", "--format=", "--name-only", "stash@{0}^3") == "folder/new.txt")
        #expect(try fixture.git("show", "stash@{0}:a.txt") == "one staged then edited")

        let stash = try #require(try await repository.snapshot().stashes.first)
        #expect(stash.isSnapshot)
        #expect(stash.title == "Before refactoring")
    }

    @Test func aSnapshotAppliesBackLater() async throws {
        defer { fixture.remove() }
        try makeChanges()
        let repository = try fixture.open()
        try await repository.saveSnapshot(message: "keep")
        let expected = try fixture.git("stash", "show", "-p", "stash@{0}")
        try fixture.git("reset", "--quiet", "--hard")
        try fixture.git("clean", "-fdq")

        let stash = try #require(try await repository.snapshot().stashes.first)
        try await repository.applyStash(stash)
        #expect(try fixture.git("diff", "HEAD") == expected)
        #expect(try fixture.textOfFile("folder/new.txt") == "new\n")
    }

    @Test func aSnapshotOfNothingIsRefused() async throws {
        defer { fixture.remove() }
        await #expect(throws: WorkingCopyError.nothingToStash) {
            try await fixture.open().saveSnapshot(message: "empty")
        }
    }

    @Test func ordinaryStashesAreNotSnapshots() async throws {
        defer { fixture.remove() }
        try fixture.write("change\n", to: "a.txt")
        try fixture.git("stash", "push", "--quiet", "-m", "plain")
        try fixture.write("change again\n", to: "a.txt")
        try fixture.git("stash", "push", "--quiet")
        let stashes = try await fixture.open().snapshot().stashes
        #expect(stashes.map(\.isSnapshot) == [false, false])
        #expect(stashes.last?.title == "plain")
        #expect(stashes.first?.title == (try fixture.git("log", "-1", "--format=%h %s")))
    }

    @Test func aBranchFromAStashMatchesGitStashBranch() async throws {
        let (ours, git) = try Fixture.twins { fixture in
            try fixture.commit("a.txt", "one\n", message: "First")
            try fixture.write("staged\n", to: "a.txt")
            try fixture.git("add", "a.txt")
            try fixture.write("unstaged\n", to: "b.txt")
            try fixture.git("add", "b.txt")
            try fixture.write("unstaged edit\n", to: "b.txt")
            try fixture.git("stash", "push", "--quiet", "-m", "work")
            // main moves on, so the branch starts where the stash was made.
            try fixture.commit("c.txt", "later\n", message: "Later")
        }
        defer { ours.remove(); git.remove() }

        let repository = try ours.open()
        let stash = try #require(try await repository.snapshot().stashes.first)
        let branch = try await repository.createBranch(fromStash: stash, named: "from-stash")
        try git.git("stash", "branch", "from-stash")

        #expect(branch == "refs/heads/from-stash")
        #expect(try ours.git("rev-parse", "--abbrev-ref", "HEAD") == "from-stash")
        #expect(try ours.git("rev-parse", "HEAD") == git.git("rev-parse", "HEAD"))
        #expect(try ours.git("status", "--porcelain") == git.git("status", "--porcelain"))
        #expect(try ours.git("diff", "--cached") == git.git("diff", "--cached"))
        #expect(try ours.git("stash", "list").isEmpty)
    }

    @Test func aBranchFromAStashThatCannotCheckOutIsNotMade() async throws {
        defer { fixture.remove() }
        try fixture.write("stashed\n", to: "b.txt")
        try fixture.git("stash", "push", "--quiet")
        try fixture.commit("b.txt", "committed\n", message: "Third")
        // A local change that checking out the stash's commit would overwrite.
        try fixture.write("local\n", to: "b.txt")

        let repository = try fixture.open()
        let stash = try #require(try await repository.snapshot().stashes.first)
        await #expect(throws: (any Error).self) {
            try await repository.createBranch(fromStash: stash, named: "nope")
        }
        #expect(try fixture.git("branch", "--list", "nope").isEmpty)
        #expect(try fixture.git("stash", "list").split(separator: "\n").count == 1)
    }

    @Test func aStashPatchMatchesGitStashShow() async throws {
        defer { fixture.remove() }
        try makeChanges()
        try fixture.git("stash", "push", "--quiet", "--include-untracked")
        let repository = try fixture.open()
        let stash = try #require(try await repository.snapshot().stashes.first)
        let patch = try await repository.patch(ofStash: stash)

        // Applied to the commit the stash was made on, it gives the
        // changes git's own patch of the stash shows.
        let file = fixture.url.appendingPathExtension("stash.patch")
        defer { try? FileManager.default.removeItem(at: file) }
        try patch.write(to: file, atomically: true, encoding: .utf8)
        try fixture.git("apply", file.path)
        #expect(try fixture.git("diff") == fixture.git("stash", "show", "-p"))
        #expect(!patch.contains("folder/new.txt"))
    }
}
