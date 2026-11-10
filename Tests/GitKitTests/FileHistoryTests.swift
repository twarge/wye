import Foundation
import GitKit
import Testing

@Suite struct FileHistoryTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    private func lines(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
    }

    private func history(
        of path: String, from commit: String, limit: Int = 100, budget: Int = 2_000
    ) async throws -> [FileHistoryEntry] {
        let repository = try fixture.open()
        let cursor = try await repository.openHistory(from: OID(hex: commit)!)
        var entries: [FileHistoryEntry] = []
        var path = path
        while true {
            let page = try await repository.nextFileHistory(from: cursor, following: path, limit: limit, examining: budget)
            entries += page.entries
            path = page.path
            if page.isComplete { break }
        }
        await repository.closeHistory(cursor)
        return entries
    }

    /// A file that is created, changed, renamed and changed again, among
    /// commits that leave it alone.
    private func makeHistory() throws -> String {
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try fixture.commit("docs/old.txt", text, message: "Create")
        try fixture.commit("other.txt", "x\n", message: "Unrelated")
        try fixture.commit("docs/old.txt", text + "line 21\n", message: "Extend")
        try fixture.git("mv", "docs/old.txt", "new.txt")
        try fixture.git("commit", "--quiet", "-m", "Rename")
        try fixture.commit("other.txt", "y\n", message: "Unrelated again")
        try fixture.commit("new.txt", "line 0\n" + text + "line 21\n", message: "Prepend")
        return try fixture.git("rev-parse", "HEAD")
    }

    @Test func followsRenamesLikeGitLogFollow() async throws {
        defer { fixture.remove() }
        let head = try makeHistory()
        let expected = lines(try fixture.git("log", "--follow", "--format=%H", "--", "new.txt"))
        #expect(expected.count == 4)

        let entries = try await history(of: "new.txt", from: head)
        #expect(entries.map(\.commit.id.hex) == expected)
        #expect(entries.map(\.change) == [.modified, .renamed, .modified, .added])
        #expect(entries.map(\.path) == ["new.txt", "new.txt", "docs/old.txt", "docs/old.txt"])
        #expect(entries[1].oldPath == "docs/old.txt")
        #expect(entries.map(\.commit.summary) == ["Prepend", "Rename", "Extend", "Create"])

        // The same a page at a time.
        #expect(try await history(of: "new.txt", from: head, limit: 1, budget: 1).map(\.commit.id.hex) == expected)
        // And from before the rename, under the old name.
        let extend = expected[2]
        #expect(try await history(of: "docs/old.txt", from: extend).map(\.commit.id.hex)
            == lines(try fixture.git("log", "--follow", "--format=%H", extend, "--", "docs/old.txt")))
    }

    @Test func listsADeletionAndReAddition() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "Add")
        try fixture.git("rm", "--quiet", "a.txt")
        try fixture.commit("b.txt", "keep\n", message: "Delete")
        let head = try fixture.commit("a.txt", "a completely different file\n", message: "Re-add")
        let expected = lines(try fixture.git("log", "--format=%H", "--", "a.txt"))
        let entries = try await history(of: "a.txt", from: head)
        #expect(entries.map(\.commit.id.hex) == expected)
        #expect(entries.map(\.change) == [.added, .deleted, .added])
    }

    @Test func fileDiffShowsOneFile() async throws {
        defer { fixture.remove() }
        let head = try makeHistory()
        let commits = lines(try fixture.git("log", "--follow", "--format=%H", "--", "new.txt"))
        let repository = try fixture.open()

        let prepend = try #require(try await repository.fileDiff(in: OID(hex: commits[0])!, path: "new.txt"))
        #expect(prepend.change == .modified)
        let numstat = try fixture.git("diff", "--numstat", "\(head)~1", head, "--", "new.txt")
        #expect("\(prepend.additions)\t\(prepend.deletions)\tnew.txt" == numstat)

        let rename = try #require(try await repository.fileDiff(in: OID(hex: commits[1])!, path: "new.txt"))
        #expect(rename.change == .renamed)
        #expect(rename.oldPath == "docs/old.txt")
        #expect(rename.path == "new.txt")

        let created = try #require(try await repository.fileDiff(in: OID(hex: commits[3])!, path: "docs/old.txt"))
        #expect(created.change == .added)
        #expect(created.additions == 20)

        // A commit that left the file alone has no diff for it.
        let unrelated = try fixture.git("rev-parse", "\(head)~1")
        #expect(try await repository.fileDiff(in: OID(hex: unrelated)!, path: "new.txt") == nil)
    }
}
