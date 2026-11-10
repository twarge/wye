import Foundation
import GitKit
import Testing

@Suite struct StashTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    @Test func savesAndDropsStashes() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.write("two\n", to: "a.txt")

        let repository = try fixture.open()
        let first = try await repository.saveStash(message: "  first try ")
        #expect(try fixture.git("stash", "list", "--format=%gs") == "On main: first try")
        #expect(try fixture.git("rev-parse", "stash@{0}") == first.hex)
        #expect(try fixture.git("status", "--porcelain").isEmpty)

        try fixture.write("three\n", to: "a.txt")
        try await repository.saveStash()
        #expect(try fixture.git("stash", "list", "--format=%gs") == "WIP on main: \(try fixture.git("log", "-1", "--format=%h %s"))\nOn main: first try")

        // Dropped by its commit, wherever it now is in the list.
        let stashes = try await repository.snapshot().stashes
        let older = try #require(stashes.first { $0.id == first })
        #expect(older.index == 1)
        try await repository.dropStash(older)
        #expect(try fixture.git("stash", "list", "--format=%gs").hasPrefix("WIP on main"))
        #expect(try fixture.git("stash", "list").split(separator: "\n").count == 1)
        await #expect(throws: WorkingCopyError.stashNotFound) { try await repository.dropStash(older) }
    }

    @Test func refusesToStashNothing() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        await #expect(throws: WorkingCopyError.nothingToStash) { try await fixture.open().saveStash() }
    }

    @Test func includesUntrackedFilesWhenAsked() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.write("two\n", to: "a.txt")
        try fixture.write("new\n", to: "new.txt")

        let repository = try fixture.open()
        try await repository.saveStash(message: "without")
        #expect(try fixture.git("status", "--porcelain") == "?? new.txt")
        try fixture.git("stash", "pop", "--quiet")

        try await repository.saveStash(message: "with", options: .includeUntracked)
        #expect(try fixture.git("status", "--porcelain").isEmpty)
        // git keeps untracked files in a third parent.
        #expect(try fixture.git("show", "--format=", "--name-only", "stash@{0}^3") == "new.txt")
    }

    @Test func keepsTheIndexWhenAsked() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.commit("b.txt", "one\n", message: "Second")
        try fixture.write("staged\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("unstaged\n", to: "b.txt")

        let repository = try fixture.open()
        try await repository.saveStash(options: .keepIndex)
        #expect(try fixture.git("status", "--porcelain") == "M  a.txt")
        #expect(try fixture.git("diff", "--name-only", "stash@{0}^1", "stash@{0}") == "a.txt\nb.txt")
    }

    @Test func appliesAndPops() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.commit("b.txt", "one\n", message: "Second")
        try fixture.write("staged\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("unstaged\n", to: "b.txt")
        try fixture.git("stash", "push", "--quiet", "-m", "work")

        let repository = try fixture.open()
        var stash = try #require(try await repository.snapshot().stashes.first)
        try await repository.applyStash(stash)
        #expect(try fixture.git("status", "--porcelain") == "M a.txt\n M b.txt")
        #expect(try fixture.git("stash", "list").split(separator: "\n").count == 1)

        try fixture.git("checkout", "--quiet", "--", ".")
        try await repository.applyStash(stash, restoringIndex: true)
        #expect(try fixture.git("status", "--porcelain") == "M  a.txt\n M b.txt")

        try fixture.git("reset", "--quiet", "--hard")
        stash = try #require(try await repository.snapshot().stashes.first)
        try await repository.popStash(stash)
        #expect(try fixture.git("stash", "list").isEmpty)
        #expect(try fixture.workingContent(of: "b.txt") == "unstaged\n")
    }

    @Test func keepsAStashThatDoesNotApply() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.write("stashed\n", to: "a.txt")
        try fixture.git("stash", "push", "--quiet")
        try fixture.write("local\n", to: "a.txt")

        let repository = try fixture.open()
        let stash = try #require(try await repository.snapshot().stashes.first)
        await #expect(throws: WorkingCopyError.stashConflictsWithChanges) { try await repository.popStash(stash) }
        #expect(try fixture.git("stash", "list").split(separator: "\n").count == 1)
        #expect(try fixture.workingContent(of: "a.txt") == "local\n")
    }
}
