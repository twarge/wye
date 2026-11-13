import Foundation
import GitKit
import Testing

extension Fixture {
    /// Writes a file and commits it with its own date, so that orders by
    /// date have something to go by.
    @discardableResult
    fileprivate func commit(_ path: String, _ text: String, message: String, minutes: Int) throws -> String {
        try write(text, to: path)
        try git("add", path)
        let date = "2026-01-02T03:\(String(format: "%02d", minutes)):00+00:00"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["commit", "--quiet", "-m", message]
        process.currentDirectoryURL = url
        process.environment = [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin",
            "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError(message: "git commit failed") }
        return try git("rev-parse", "HEAD")
    }
}

/// Two branches whose commits alternate in time, merged twice, so that
/// date order interleaves them and topological order keeps them apart.
private func interleaved(_ fixture: Fixture) throws {
    try fixture.commit("a.txt", "0\n", message: "Base", minutes: 0)
    try fixture.git("checkout", "--quiet", "-b", "topic")
    try fixture.commit("t.txt", "1\n", message: "Topic 1", minutes: 1)
    try fixture.git("checkout", "--quiet", "main")
    try fixture.commit("a.txt", "2\n", message: "Main 2", minutes: 2)
    try fixture.git("checkout", "--quiet", "topic")
    try fixture.commit("t.txt", "3\n", message: "Topic 3", minutes: 3)
    try fixture.git("checkout", "--quiet", "main")
    try fixture.commit("a.txt", "4\n", message: "Main 4", minutes: 4)
    try fixture.git("merge", "--quiet", "--no-ff", "--no-edit", "topic")
    try fixture.git("checkout", "--quiet", "topic")
    try fixture.commit("t.txt", "5\n", message: "Topic 5", minutes: 6)
    try fixture.git("checkout", "--quiet", "-b", "side", "main~1")
    try fixture.commit("s.txt", "7\n", message: "Side 7", minutes: 7)
    try fixture.git("checkout", "--quiet", "main")
    try fixture.commit("a.txt", "8\n", message: "Main 8", minutes: 8)
}

/// A main line with a branch on top of it, an unmerged branch and a newer
/// one off its middle, and an old one-commit stub that only a tag keeps:
/// the shape of a history whose stale lines came out first when the walk
/// took its tips in the order of their names rather than their dates.
private struct Stubs {
    /// `HEAD`'s line, newest first, from the branch on top of it down.
    var mainLine: [String]
    var feature: String
    var newest: String
    var stub: String
}

@discardableResult
private func stubs(_ fixture: Fixture) throws -> Stubs {
    let base = try fixture.commit("a.txt", "0\n", message: "Base", minutes: 0)
    let first = try fixture.commit("a.txt", "1\n", message: "Main 1", minutes: 1)
    try fixture.git("checkout", "--quiet", "--detach")
    let stub = try fixture.commit("s.txt", "2\n", message: "Stub 2", minutes: 2)
    try fixture.git("tag", "v1")
    try fixture.git("checkout", "--quiet", "main")
    let middle = try fixture.commit("a.txt", "3\n", message: "Main 3", minutes: 3)
    try fixture.git("checkout", "--quiet", "-b", "feature")
    let feature = try fixture.commit("f.txt", "4\n", message: "Feature 4", minutes: 4)
    try fixture.git("checkout", "--quiet", "main")
    let head = try fixture.commit("a.txt", "5\n", message: "Main 5", minutes: 5)
    try fixture.git("checkout", "--quiet", "-b", "ahead")
    let ahead = try fixture.commit("a.txt", "6\n", message: "Ahead 6", minutes: 6)
    try fixture.git("checkout", "--quiet", "-b", "newest", middle)
    let newest = try fixture.commit("n.txt", "7\n", message: "Newest 7", minutes: 7)
    try fixture.git("checkout", "--quiet", "main")
    return Stubs(mainLine: [ahead, head, middle, first, base], feature: feature, newest: newest, stub: stub)
}

@Suite struct HistoryOptionsTests {
    private func walk(_ fixture: Fixture, _ scope: HistoryScope, _ options: HistoryOptions) async throws -> [String] {
        let repository = try fixture.open()
        let cursor = try await repository.openHistory(scope, options: options)
        defer { Task { await repository.closeHistory(cursor) } }
        return try await repository.nextCommits(from: cursor, limit: 1_000).map(\.id.hex)
    }

    private func gitLog(_ fixture: Fixture, _ arguments: String...) throws -> [String] {
        try Fixture.run(["log", "--format=%H"] + arguments, in: fixture.url).split(separator: "\n").map(String.init)
    }

    @Test func theCommitsAMergeBroughtInMatchGit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try interleaved(fixture)
        let repository = try fixture.open()
        let merge = try fixture.git("rev-parse", "main~1")
        let merged = try await repository.commitsMerged(by: OID(hex: merge)!).map(\.hex)
        #expect(Set(merged) == Set(try gitLog(fixture, "\(merge)^2", "^\(merge)^1")))
        #expect(merged.count == 2)
        // Not a merge: nothing to fold.
        let plain = try fixture.git("rev-parse", "main")
        #expect(try await repository.commitsMerged(by: OID(hex: plain)!).isEmpty)
    }

    @Test func dateOrderMatchesGit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try interleaved(fixture)
        #expect(try await walk(fixture, .reference("refs/heads/main"), HistoryOptions(order: .date))
            == gitLog(fixture, "--date-order", "main"))
        #expect(try await walk(fixture, .allReferences, HistoryOptions(order: .date))
            == gitLog(fixture, "--date-order", "--branches", "--tags", "HEAD"))
    }

    @Test func topologicalOrderKeepsLinesTogether() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try interleaved(fixture)
        let ours = try await walk(fixture, .reference("refs/heads/main"), HistoryOptions(order: .topological))
        #expect(ours == (try gitLog(fixture, "--topo-order", "main")))
        // Children before parents, whatever the dates.
        let position = Dictionary(uniqueKeysWithValues: ours.enumerated().map { ($1, $0) })
        for line in try fixture.git("log", "--format=%H %P", "main").split(separator: "\n") {
            let ids = line.split(separator: " ").map(String.init)
            for parent in ids.dropFirst() {
                #expect(position[ids[0]]! < position[parent]!)
            }
        }
    }

    @Test func firstParentMatchesGit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try interleaved(fixture)
        for order in HistoryOptions.Order.allCases {
            let options = HistoryOptions(order: order, firstParentOnly: true)
            #expect(try await walk(fixture, .reference("refs/heads/main"), options)
                == gitLog(fixture, "--first-parent", order == .date ? "--date-order" : "--topo-order", "main"))
        }
        let count = try await fixture.open().commitCount(
            in: .reference("refs/heads/main"), options: HistoryOptions(firstParentOnly: true)
        )
        #expect(count == (try gitLog(fixture, "--first-parent", "main").count))
    }

    @Test func aFirstParentGraphHasOneLane() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try interleaved(fixture)
        let repository = try fixture.open()
        let cursor = try await repository.openHistory(.reference("refs/heads/main"),
                                                      options: HistoryOptions(firstParentOnly: true))
        var graph = CommitGraph()
        for commit in try await repository.nextCommits(from: cursor, limit: 100) {
            let row = graph.append(commit.id, parents: Array(commit.parentIDs.prefix(1)))
            #expect(row.lane == 0)
            #expect(row.width == 1)
        }
        await repository.closeHistory(cursor)
    }

    @Test func topologicalOrderOfEveryBranchMatchesGit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try stubs(fixture)
        // Each line newest first, the stub beside the commit it left, not
        // ahead of everything for its name.
        #expect(try await walk(fixture, .allReferences, HistoryOptions(order: .topological))
            == gitLog(fixture, "--topo-order", "--branches", "--tags", "HEAD"))
        #expect(try await walk(fixture, .allReferences, HistoryOptions(order: .date))
            == gitLog(fixture, "--date-order", "--branches", "--tags", "HEAD"))
    }

    @Test func theMainLineRisesFromHeadToTheBranchOnTopOfIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shape = try stubs(fixture)
        let repository = try fixture.open()
        let ahead = OID(hex: shape.mainLine[0])
        // Not the newest branch, which left the main line lower down.
        #expect(try await repository.mainLine(of: .allReferences) == ahead)
        #expect(try await repository.mainLine(of: .allReferences, options: HistoryOptions(
            includedReferences: ["refs/heads/ahead"]
        )) == ahead)
        #expect(try await repository.mainLine(of: .reference("refs/heads/feature")) == OID(hex: shape.feature))
        // A history that does not list HEAD has none.
        #expect(try await repository.mainLine(of: .allReferences, options: HistoryOptions(
            includedReferences: ["refs/heads/newest"]
        )) == nil)
        #expect(try await repository.mainLine(of: .allReferences, options: HistoryOptions(
            hiddenReferences: ["refs/heads/main"]
        )) == nil)
    }

    @Test func theMainLineStaysStraightInTheFirstLane() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shape = try stubs(fixture)
        let repository = try fixture.open()
        for order in HistoryOptions.Order.allCases {
            let options = HistoryOptions(order: order)
            let cursor = try await repository.openHistory(.allReferences, options: options)
            var graph = CommitGraph(mainLine: try await repository.mainLine(of: .allReferences, options: options))
            var lanes: [String: Int] = [:]
            for commit in try await repository.nextCommits(from: cursor, limit: 100) {
                lanes[commit.id.hex] = graph.append(commit.id, parents: commit.parentIDs).lane
            }
            await repository.closeHistory(cursor)
            let mainLine = Set(shape.mainLine)
            #expect(lanes.filter { mainLine.contains($0.key) }.values.allSatisfy { $0 == 0 }, "\(order)")
            #expect(lanes.filter { !mainLine.contains($0.key) }.values.allSatisfy { $0 > 0 }, "\(order)")
            #expect(lanes.count == 8)
        }
    }
}
