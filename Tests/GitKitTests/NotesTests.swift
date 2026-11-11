import Foundation
import GitKit
import Testing

/// Notes on commits, against `git notes`.
@Suite struct NotesTests {
    private func makeFixture() throws -> (Fixture, [String]) {
        let fixture = try Fixture()
        let ids = try (1...3).map { try fixture.commit("a.txt", "\($0)\n", message: "Commit \($0)") }
        return (fixture, ids)
    }

    @Test func readsWhatGitWrote() async throws {
        let (fixture, ids) = try makeFixture()
        defer { fixture.remove() }
        let repository = try fixture.open()
        let first = try #require(OID(hex: ids[0]))
        #expect(try await repository.note(for: first) == nil)
        #expect(try await repository.notedCommits().isEmpty)

        try fixture.git("notes", "add", "-m", "Reviewed\n\nBy someone", ids[0])
        try fixture.git("notes", "add", "-m", "Second", ids[2])
        let note = try #require(try await repository.note(for: first))
        #expect(note.trimmingCharacters(in: .newlines) == (try fixture.git("notes", "show", ids[0])))
        #expect(try await repository.notedCommits() == Set([ids[0], ids[2]].compactMap(OID.init(hex:))))
    }

    @Test func gitReadsWhatWeWrite() async throws {
        let (fixture, ids) = try makeFixture()
        defer { fixture.remove() }
        let repository = try fixture.open()
        let second = try #require(OID(hex: ids[1]))
        try await repository.setNote("Needs a test\n\n", for: second)
        #expect(try fixture.git("notes", "show", ids[1]) == "Needs a test")
        // `git notes add` keeps the text with one line break at its end.
        let blob = try fixture.git("notes", "list", ids[1])
        #expect(try Fixture.run(["cat-file", "-p", blob], in: fixture.url) == "Needs a test")
        #expect(try fixture.git("cat-file", "-s", blob) == "13")

        try await repository.setNote("Replaced", for: second)
        #expect(try fixture.git("notes", "show", ids[1]) == "Replaced")
        #expect(try fixture.git("notes", "list").split(separator: "\n").count == 1)
    }

    @Test func removing() async throws {
        let (fixture, ids) = try makeFixture()
        defer { fixture.remove() }
        let repository = try fixture.open()
        try fixture.git("notes", "add", "-m", "Gone soon", ids[2])
        let third = try #require(OID(hex: ids[2]))
        try await repository.removeNote(for: third)
        #expect(try fixture.git("notes", "list") == "")
        // Removing a note that is not there, or setting an empty one, is fine.
        try await repository.removeNote(for: third)
        try await repository.setNote("  \n", for: third)
        #expect(try await repository.note(for: third) == nil)
    }
}
