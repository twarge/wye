import Foundation
import GitKit
import Testing

@Suite struct ReflogTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    private func gitReflog(_ reference: String) throws -> [(id: String, message: String)] {
        try fixture.git("reflog", "show", "--format=%H%x09%gs", reference).split(separator: "\n").map { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        }
    }

    private func makeHistory() throws {
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.commit("a.txt", "two\n", message: "Second")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        try fixture.commit("b.txt", "topic\n", message: "On topic")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.git("reset", "--quiet", "--hard", "HEAD~1")
    }

    @Test func headReflogMatchesGit() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let entries = try await fixture.open().reflog()
        let expected = try gitReflog("HEAD")
        #expect(entries.count == expected.count)
        #expect(entries.map(\.newID.hex) == expected.map(\.id))
        #expect(entries.map(\.message) == expected.map(\.message))
        #expect(entries.map(\.index) == Array(0..<expected.count))
        #expect(entries.first?.message.hasPrefix("reset: moving to HEAD~1") == true)
        #expect(entries.allSatisfy { $0.committer.name == "Test Author" && $0.committer.email == "author@example.com" })

        // Each entry starts where the one before it ended; the first creates HEAD.
        for (newer, older) in zip(entries, entries.dropFirst()) {
            #expect(newer.oldID == older.newID)
        }
        #expect(entries.last?.oldID == nil)
    }

    @Test func branchReflogMatchesGit() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let repository = try fixture.open()
        for reference in ["refs/heads/main", "refs/heads/topic"] {
            let entries = try await repository.reflog(of: reference)
            let expected = try gitReflog(reference)
            #expect(entries.map(\.newID.hex) == expected.map(\.id), "\(reference)")
            #expect(entries.map(\.message) == expected.map(\.message))
        }
    }

    @Test func aReferenceWithoutAReflogHasNoEntries() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        // git keeps no reflog for tags unless asked to.
        try fixture.git("tag", "quiet")
        #expect(try await fixture.open().reflog(of: "refs/tags/quiet").isEmpty)
    }
}
