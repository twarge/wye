import Foundation
import GitKit
import Testing

/// Filters by date, author and branch, against `git log --since`, `--until`,
/// `--author` and the branches it is given.
@Suite struct HistoryFilterTests {
    /// Commits a file as `author` on a given day of January 2026.
    @discardableResult
    private func commit(_ fixture: Fixture, _ path: String, day: Int, author: (String, String)) throws -> String {
        try fixture.write("\(day)\n", to: path)
        try fixture.git("add", path)
        let date = String(format: "2026-01-%02dT12:00:00+00:00", day)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["commit", "--quiet", "-m", "Day \(day)"]
        process.currentDirectoryURL = fixture.url
        process.environment = [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin",
            "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date,
            "GIT_AUTHOR_NAME": author.0, "GIT_AUTHOR_EMAIL": author.1
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError(message: "git commit failed") }
        return try fixture.git("rev-parse", "HEAD")
    }

    private let ada = ("Ada", "ada@example.com")
    private let bo = ("Bo", "bo@example.com")

    /// `main` with days 1 to 6, `topic` from day 3 with days 7 to 9, and
    /// `side` from day 2 with day 10. Authors alternate.
    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture()
        for day in 1...6 {
            try commit(fixture, "main.txt", day: day, author: day.isMultiple(of: 2) ? bo : ada)
        }
        try fixture.git("checkout", "--quiet", "-b", "topic", "main~3")
        for day in 7...9 {
            try commit(fixture, "topic.txt", day: day, author: day.isMultiple(of: 2) ? bo : ada)
        }
        try fixture.git("checkout", "--quiet", "-b", "side", "main~4")
        try commit(fixture, "side.txt", day: 10, author: bo)
        try fixture.git("checkout", "--quiet", "main")
        return fixture
    }

    private func gitLog(_ fixture: Fixture, _ arguments: [String]) throws -> [String] {
        try Fixture.run(["log", "--format=%H", "--date-order"] + arguments, in: fixture.url)
            .split(separator: "\n").map(String.init)
    }

    private func filtered(
        _ fixture: Fixture, _ scope: HistoryScope = .allReferences, options: HistoryOptions = HistoryOptions(),
        filter: HistoryFilter = HistoryFilter(), query: HistoryQuery = HistoryQuery(.message, "")
    ) async throws -> [String] {
        let repository = try fixture.open()
        let cursor = try await repository.openHistory(scope, options: options)
        var found: [String] = []
        while true {
            let page = try await repository.nextMatches(from: cursor, matching: query, filter: filter, limit: 2, examining: 3)
            found += page.matches.map(\.id.hex)
            if page.isComplete { break }
        }
        await repository.closeHistory(cursor)
        return found
    }

    private func day(_ day: Int, hour: Int = 0) -> Date {
        var components = DateComponents(year: 2026, month: 1, day: day, hour: hour)
        components.timeZone = .gmt
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func datesMatchSinceAndUntil() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let all = ["--branches"]
        #expect(try await filtered(fixture, filter: HistoryFilter(since: day(4)))
            == gitLog(fixture, all + ["--since=2026-01-04T00:00:00Z"]))
        #expect(try await filtered(fixture, filter: HistoryFilter(until: day(5)))
            == gitLog(fixture, all + ["--until=2026-01-05T00:00:00Z"]))
        let range = try await filtered(fixture, filter: HistoryFilter(since: day(3), until: day(8)))
        #expect(range == (try gitLog(fixture, all + ["--since=2026-01-03T00:00:00Z", "--until=2026-01-08T00:00:00Z"])))
        #expect(range.count == 5)
    }

    @Test func authorsMatchGit() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let bo = HistoryFilter.Author(name: "Bo", email: "bo@example.com")
        let ada = HistoryFilter.Author(name: "Ada", email: "ada@example.com")
        #expect(try await filtered(fixture, filter: HistoryFilter(authors: [bo]))
            == gitLog(fixture, ["--branches", "--author=bo@example.com"]))
        #expect(try await filtered(fixture, filter: HistoryFilter(authors: [bo, ada]))
            == gitLog(fixture, ["--branches"]))
        // Combined with a date and a text search.
        let combined = try await filtered(
            fixture, filter: HistoryFilter(since: day(5), authors: [ada]), query: HistoryQuery(.message, "day")
        )
        #expect(combined == (try gitLog(fixture, ["--branches", "--author=ada@", "--since=2026-01-05T00:00:00Z",
                                                  "-i", "--grep=day"])))
    }

    @Test func includedBranchesMatchGit() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let options = HistoryOptions(includedReferences: ["refs/heads/topic", "refs/heads/side"])
        #expect(try await filtered(fixture, options: options) == gitLog(fixture, ["topic", "side"]))
        let count = try await fixture.open().commitCount(in: .allReferences, options: options)
        #expect(count == (try gitLog(fixture, ["topic", "side"]).count))
    }

    @Test func hiddenBranchesMatchGit() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let options = HistoryOptions(hiddenReferences: ["refs/heads/main"])
        #expect(try await filtered(fixture, options: options) == gitLog(fixture, ["--branches", "^main"]))
        // One branch's own history, with another hidden.
        #expect(try await filtered(fixture, .reference("refs/heads/topic"), options: options)
            == gitLog(fixture, ["topic", "^main"]))
        // A branch that has gone hides nothing.
        let gone = HistoryOptions(hiddenReferences: ["refs/heads/gone"])
        #expect(try await filtered(fixture, options: gone) == gitLog(fixture, ["--branches"]))
    }

    @Test func filtersCombineWithBranches() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let options = HistoryOptions(includedReferences: ["refs/heads/topic"], hiddenReferences: ["refs/heads/side"])
        let bo = HistoryFilter.Author(name: "Bo", email: "bo@example.com")
        #expect(try await filtered(fixture, options: options, filter: HistoryFilter(authors: [bo]))
            == gitLog(fixture, ["topic", "^side", "--author=bo@"]))
    }

    @Test func commitDatesAreCommitterDates() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let head = try #require(OID(hex: try fixture.git("rev-parse", "HEAD")))
        let dates = await (try fixture.open()).commitDates(of: [head])
        #expect(dates[head] == day(6, hour: 12))
    }
}
