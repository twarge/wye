import Foundation
import GitKit
import Testing

@Suite struct SearchTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    /// A history with two authors, a branch and a merge.
    private func makeHistory() throws {
        try fixture.commit("README.md", "hello\n", message: "Add the README")
        try fixture.commit("src/app/main.swift", "print(1)\n", message: "Fix the login bug\n\nIt was the cookie.")
        try fixture.write("print(2)\n", to: "src/app/main.swift")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "--author=Other Person <other@example.org>", "-m", "Speed up launch")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        try fixture.commit("src/lib/util.swift", "let x = 1\n", message: "Add a helper")
        try fixture.write("hello again\n", to: "README.md")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "--author=Other Person <other@example.org>", "-m", "Reword the readme, FIX typo")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.commit("src/app/main.swift", "print(3)\n", message: "Change main")
        try fixture.git("merge", "--quiet", "--no-ff", "-m", "Merge topic", "topic")
    }

    private func search(
        _ query: HistoryQuery, in scope: HistoryScope = .allReferences, limit: Int = 100, budget: Int = 2_000
    ) async throws -> [String] {
        let repository = try fixture.open()
        let cursor = try await repository.openHistory(scope)
        defer { Task { await repository.closeHistory(cursor) } }
        var found: [String] = []
        while true {
            let page = try await repository.nextMatches(from: cursor, matching: query, limit: limit, examining: budget)
            found += page.matches.map(\.id.hex)
            if page.isComplete { break }
        }
        return found
    }

    private func lines(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
    }

    @Test func messageMatchesGitGrep() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let expected = lines(try fixture.git("log", "--all", "-i", "-F", "--grep=fix", "--format=%H"))
        #expect(expected.count == 2)
        #expect(Set(try await search(HistoryQuery(.message, "fix"))) == Set(expected))
        // The body is searched too.
        let cookie = lines(try fixture.git("log", "--all", "-i", "-F", "--grep=COOKIE", "--format=%H"))
        #expect(try await search(HistoryQuery(.message, "COOKIE")) == cookie)
    }

    @Test func authorMatchesGitAuthor() async throws {
        defer { fixture.remove() }
        try makeHistory()
        for term in ["other", "author@example.com", "Test Author <"] {
            let expected = lines(try fixture.git("log", "--all", "-i", "-F", "--author=\(term)", "--format=%H"))
            #expect(!expected.isEmpty)
            #expect(Set(try await search(HistoryQuery(.author, term))) == Set(expected))
        }
    }

    @Test func hashMatchesAPrefix() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let all = lines(try fixture.git("rev-list", "--all"))
        let target = all[2]
        let prefix = String(target.prefix(6))
        let expected = all.filter { $0.hasPrefix(prefix) }
        #expect(try await search(HistoryQuery(.hash, prefix.uppercased())) == expected)
        #expect(try await search(HistoryQuery(.hash, "  " + target + " ")) == [target])
    }

    /// Whether git sees a difference in `path` between two commits.
    private func differs(_ from: String, _ to: String, in path: String) -> Bool {
        (try? fixture.git("diff", "--quiet", from, to, "--", path)) == nil
    }

    @Test func pathMatchesGitLogFullHistory() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let merges = lines(try fixture.git("rev-list", "--all", "--merges"))
        #expect(merges.count == 1)
        for path in ["src/app/main.swift", "src", "src/lib", "README.md", "missing.txt"] {
            let found = try await search(HistoryQuery(.path, path))
            let commits = lines(try fixture.git("log", "--all", "--full-history", "--no-merges", "--format=%H", "--", path))
            // A merge counts when it differs from both its parents.
            let changingMerges = merges.filter { differs("\($0)^1", $0, in: path) && differs("\($0)^2", $0, in: path) }
            #expect(Set(found) == Set(commits + changingMerges), "\(path)")
        }
        // Here only `src` changed on both sides, so only it lists the merge.
        #expect(try await search(HistoryQuery(.path, "src")).first == merges.first)
        #expect(try await search(HistoryQuery(.path, "README.md")).contains(merges[0]) == false)
        // A folder is found with or without its slash.
        #expect(Set(try await search(HistoryQuery(.path, "src/"))) == Set(try await search(HistoryQuery(.path, "src"))))
    }

    @Test func resultsKeepTheHistoryOrder() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let repository = try fixture.open()
        let cursor = try await repository.openHistory(.allReferences)
        let history = try await repository.nextCommits(from: cursor, limit: 100).map(\.id.hex)
        await repository.closeHistory(cursor)
        let found = try await search(HistoryQuery(.path, "src"))
        #expect(found == history.filter(found.contains))
        // An empty query lists everything.
        #expect(try await search(HistoryQuery(.message, " ")) == history)
    }

    @Test func searchesPageByPage() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let whole = try await search(HistoryQuery(.author, "author"))
        // One commit examined per call still finds everything, in order.
        #expect(try await search(HistoryQuery(.author, "author"), limit: 1, budget: 1) == whole)

        let repository = try fixture.open()
        let cursor = try await repository.openHistory(.reference("refs/heads/main"))
        let page = try await repository.nextMatches(from: cursor, matching: HistoryQuery(.message, "zzz"), limit: 10, examining: 3)
        #expect(page.matches.isEmpty)
        #expect(page.examined == 3)
        #expect(!page.isComplete)
        // Closing the cursor abandons the search.
        await repository.closeHistory(cursor)
        let after = try await repository.nextMatches(from: cursor, matching: HistoryQuery(.message, "zzz"), limit: 10)
        #expect(after.isComplete)
        #expect(after.examined == 0)
    }

    @Test func scopeLimitsTheSearch() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let expected = lines(try fixture.git("log", "topic", "-i", "-F", "--grep=fix", "--format=%H"))
        #expect(try await search(HistoryQuery(.message, "fix"), in: .reference("refs/heads/topic")) == expected)
    }
}
