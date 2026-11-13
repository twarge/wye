import Foundation
import GitKit
import Testing

/// Searching what commits changed in their files, against `git log -G`
/// with `-i`, which finds the same commits for a plain string.
@Suite struct ContentSearchTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    private func search(
        _ text: String, in scope: HistoryScope = .allReferences, options: HistoryOptions = HistoryOptions(),
        budget: Int = 2_000
    ) async throws -> [String] {
        let repository = try fixture.open()
        let cursor = try await repository.openHistory(scope, options: options)
        defer { Task { await repository.closeHistory(cursor) } }
        var found: [String] = []
        while true {
            let page = try await repository.nextMatches(
                from: cursor, matching: HistoryQuery(.contents, text), limit: 100, examining: budget
            )
            found += page.matches.map(\.id.hex)
            if page.isComplete { break }
        }
        return found
    }

    private func gitLog(_ arguments: String...) throws -> [String] {
        try Fixture.run(["log", "--all", "--format=%H"] + arguments, in: fixture.url)
            .split(separator: "\n").map(String.init)
    }

    /// A line holding "gamma" added, rewritten in place, removed, left
    /// alone, moved with its file and brought in by a merge, and a binary
    /// file holding it.
    @discardableResult
    private func makeHistory() throws -> [String: String] {
        var commits: [String: String] = [:]
        commits["first"] = try fixture.commit("a.txt", "alpha\nbeta\n", message: "First")
        commits["added"] = try fixture.commit("a.txt", "alpha\nGamma ray\nbeta\n", message: "Add a line")
        commits["rewritten"] = try fixture.commit("a.txt", "alpha\nGamma rays\nbeta\n", message: "Reword it")
        commits["elsewhere"] = try fixture.commit("b.txt", "nothing here\n", message: "Another file")
        commits["removed"] = try fixture.commit("a.txt", "alpha\nbeta\n", message: "Take it out")
        commits["keeper"] = try fixture.commit("c.txt", "gamma stays\n", message: "A file that keeps it")
        try fixture.git("mv", "c.txt", "d.txt")
        try fixture.git("commit", "--quiet", "-m", "Move it unchanged")
        commits["moved"] = try fixture.git("rev-parse", "HEAD")
        commits["untouched"] = try fixture.commit("b.txt", "still nothing\n", message: "Touch the other file")

        let binary = fixture.url.appending(path: "image.bin")
        try Data([0, 1, 2] + Array("gamma".utf8) + [0, 255]).write(to: binary)
        try fixture.git("add", "image.bin")
        try fixture.git("commit", "--quiet", "-m", "A binary file")
        commits["binary"] = try fixture.git("rev-parse", "HEAD")

        try fixture.git("checkout", "--quiet", "-b", "topic")
        commits["topic"] = try fixture.commit("t.txt", "a GAMMA on a branch\n", message: "On the branch")
        try fixture.git("checkout", "--quiet", "main")
        commits["main"] = try fixture.commit("m.txt", "main moves on\n", message: "On main")
        try fixture.git("merge", "--quiet", "--no-ff", "-m", "Merge topic", "topic")
        commits["merge"] = try fixture.git("rev-parse", "HEAD")
        return commits
    }

    @Test func matchesGitLogG() async throws {
        defer { fixture.remove() }
        let commits = try makeHistory()
        let expected = try gitLog("-i", "-G", "gamma")
        let found = try await search("gamma")
        #expect(Set(found) == Set(expected))
        #expect(Set(found) == Set([commits["added"], commits["rewritten"], commits["removed"],
                                   commits["keeper"], commits["topic"]].compactMap { $0 }))
        // The history's order, newest first.
        #expect(found == (try gitLog()).filter(found.contains))
        // Case is ignored either way round, and space around the text.
        #expect(try await search("  GAMMA ") == found)
    }

    @Test func passesOverWhatDidNotChangeALine() async throws {
        defer { fixture.remove() }
        let commits = try makeHistory()
        let found = Set(try await search("gamma"))
        // A file holding it, left alone or moved, and a binary one.
        for name in ["elsewhere", "untouched", "moved", "binary", "first"] {
            #expect(!found.contains(commits[name]!), "\(name)")
        }
        // A merge brings in its branch's lines: the branch's commit is listed.
        #expect(!found.contains(commits["merge"]!))
        #expect(try await search("zeta").isEmpty)
    }

    @Test func aMergeStandsForItsBranchAlongFirstParents() async throws {
        defer { fixture.remove() }
        let commits = try makeHistory()
        let options = HistoryOptions(firstParentOnly: true)
        let found = try await search("gamma", in: .reference("refs/heads/main"), options: options)
        let expected = try Fixture.run(["log", "--first-parent", "--format=%H", "-i", "-G", "gamma", "main"],
                                       in: fixture.url).split(separator: "\n").map(String.init)
        #expect(Set(found) == Set(expected))
        #expect(found.contains(commits["merge"]!))
        #expect(!found.contains(commits["topic"]!))
    }

    @Test func findsTextOutsideASCII() async throws {
        defer { fixture.remove() }
        let added = try fixture.commit("notes.txt", "Ärger im Büro\n", message: "Add notes")
        try fixture.commit("notes.txt", "Ärger im Büro\nmehr\n", message: "More notes")
        #expect(try await search("ärger") == [added])
        #expect(try await search("BÜRO") == [added])
    }

    @Test func skipsVeryLargeFiles() async throws {
        defer { fixture.remove() }
        let small = try fixture.commit("small.txt", "needle\n", message: "Small")
        let line = String(repeating: "x", count: 99) + "\n"
        try fixture.commit("large.txt", String(repeating: line, count: 25_000) + "needle\n", message: "Large")
        #expect(try await search("needle") == [small])
    }

    @Test func searchesPageByPage() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let whole = try await search("gamma")
        #expect(try await search("gamma", budget: 1) == whole)
    }
}
