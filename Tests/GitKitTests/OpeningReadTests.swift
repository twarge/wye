import Foundation
import GitKit
import Testing

/// What a window opens with, read in one turn: the top of the history, and
/// a snapshot that leaves the submodules' files alone.
@Suite struct OpeningReadTests {
    private func log(_ fixture: Fixture) throws -> [String] {
        try fixture.git("log", "--format=%H").split(separator: "\n").map(String.init)
    }

    @Test func theTopOfAHistoryIsItsFirstCommitsAndCarriesOn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for number in 1...5 {
            try fixture.commit("file.txt", "\(number)\n", message: "Commit \(number)")
        }
        let repository = try fixture.open()
        let log = try log(fixture)

        let start = try await repository.startHistory(.allReferences, limit: 2)
        #expect(start.commits.map(\.id.hex) == Array(log.prefix(2)))
        #expect(start.mainLine?.hex == log.first)
        // The same as the history read a step at a time.
        let cursor = try await repository.openHistory(.allReferences)
        #expect(try await repository.nextCommits(from: cursor, limit: 2) == start.commits)
        #expect(try await repository.mainLine(of: .allReferences) == start.mainLine)

        let rest = try await repository.nextCommits(from: start.cursor, limit: 10)
        #expect(rest.map(\.id.hex) == Array(log.dropFirst(2)))
    }

    @Test func startingAgainClosesTheHistoryReadBefore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for number in 1...3 {
            try fixture.commit("file.txt", "\(number)\n", message: "Commit \(number)")
        }
        let repository = try fixture.open()

        let first = try await repository.startHistory(.allReferences, limit: 1)
        let second = try await repository.startHistory(.allReferences, limit: 1, closing: first.cursor)
        #expect(try await repository.nextCommits(from: first.cursor, limit: 10).isEmpty)
        #expect(try await repository.nextCommits(from: second.cursor, limit: 10).count == 2)
    }

    @Test func aRepositoryWithNoCommitsHasAnEmptyTop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let start = try await fixture.open().startHistory(.allReferences, limit: 10)
        #expect(start.commits.isEmpty)
        #expect(start.mainLine == nil)
    }

    @Test func severalReadsShareOneTurn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("file.txt", "one\n", message: "One")
        try fixture.write("new\n", to: "new.txt")
        let repository = try fixture.open()

        let (head, entries, start) = try await repository.read { repository in
            (try repository.head(), try repository.status(), try repository.startHistory(.allReferences, limit: 10))
        }
        #expect(head.target?.hex == (try fixture.git("rev-parse", "HEAD")))
        #expect(entries.map(\.path) == ["new.txt"])
        #expect(start.commits.map(\.summary) == ["One"])
    }

    @Test func aSnapshotCanLeaveASubmodulesFilesUnread() async throws {
        let fixture = try SubmoduleFixture()
        defer { fixture.remove() }
        let lib = try fixture.makeLibrary("lib")
        try fixture.main.submoduleGit("submodule", "--quiet", "add", lib.path, "lib")
        try fixture.main.git("commit", "--quiet", "-m", "Add lib")
        let inner = Fixture(existing: fixture.main.url.appending(path: "lib"))
        try inner.git("config", "user.name", "Test Author")
        try inner.git("config", "user.email", "author@example.com")
        try inner.write("edited\n", to: "file.txt")
        try inner.write("new\n", to: "untracked.txt")
        let repository = try fixture.main.open()

        // Listed all the same, at its commit, without what changed inside it.
        let full = try await repository.snapshot()
        var light = try await repository.snapshot(scanningSubmodules: false)
        #expect(full.submodules.map(\.status) == [.modifiedContent])
        #expect(light.submodules.map(\.status) == [.upToDate])
        #expect(light.submodules.map(\.name) == full.submodules.map(\.name))
        #expect(light.submodules.map(\.checkedOutID) == full.submodules.map(\.checkedOutID))
        #expect(light.head == full.head)
        #expect(light.branches == full.branches)

        // Another commit checked out shows without looking through the files.
        try inner.git("checkout", "--quiet", "--", ".")
        try inner.commit("file.txt", "three\n", message: "Three")
        light = try await repository.snapshot(scanningSubmodules: false)
        #expect(light.submodules.map(\.status) == [.differentCommit])

        // The working copy still says what changed inside a submodule.
        try inner.write("edited again\n", to: "file.txt")
        let entry = try #require(try await repository.status().first { $0.path == "lib" })
        #expect(entry.submodule?.contains(.modifiedContent) == true)
        #expect(entry.submodule?.contains(.untrackedContent) == true)
    }
}
