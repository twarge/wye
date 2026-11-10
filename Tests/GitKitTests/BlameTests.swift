import Foundation
import GitKit
import Testing

@Suite struct BlameTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    /// The commit and text of each line, from `git blame --porcelain`.
    private func gitBlame(_ path: String, at commit: String) throws -> [(commit: String, text: String)] {
        var result: [(String, String)] = []
        var current = ""
        for line in try fixture.git("blame", "--porcelain", commit, "--", path).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                result.append((current, String(line.dropFirst())))
            } else if let first = line.split(separator: " ").first, first.count == 40,
                      first.allSatisfy(\.isHexDigit) {
                current = String(first)
            }
        }
        return result
    }

    private func perLine(_ blame: Blame) -> [(commit: String, text: String)] {
        blame.runs.flatMap { run in run.lines.map { (run.commitID.hex, $0) } }
    }

    private func makeHistory() throws -> [String] {
        let first = try fixture.commit("file.txt", "a\nb\nc\nd\ne\n", message: "First")
        try fixture.write("a\nB\nc\nd\ne\nf\n", to: "file.txt")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "--author=Other Person <other@example.org>", "-m", "Second\n\nBody text.")
        let second = try fixture.git("rev-parse", "HEAD")
        let third = try fixture.commit("file.txt", "zero\na\nB\nc\nd\ne\nf\n", message: "Third")
        return [first, second, third]
    }

    @Test func linesMatchGitBlame() async throws {
        defer { fixture.remove() }
        let commits = try makeHistory()
        let repository = try fixture.open()
        for commit in commits {
            let blame = try await repository.blame(of: "file.txt", at: OID(hex: commit)!)
            let expected = try gitBlame("file.txt", at: commit)
            let actual = perLine(blame)
            #expect(actual.map(\.commit) == expected.map(\.commit), "at \(commit)")
            #expect(actual.map(\.text) == expected.map(\.text))
            #expect(blame.lineCount == expected.count)
        }
    }

    @Test func runsGroupLinesWithTheirCommit() async throws {
        defer { fixture.remove() }
        let commits = try makeHistory()
        let blame = try await fixture.open().blame(of: "file.txt", at: OID(hex: commits[2])!)
        // zero | a | B | c d e | f
        #expect(blame.runs.map(\.commitID.hex) == [commits[2], commits[0], commits[1], commits[0], commits[1]])
        #expect(blame.runs.map(\.startLine) == [1, 2, 3, 4, 7])
        #expect(blame.runs.map(\.lines.count) == [1, 1, 1, 3, 1])
        // Neighbouring runs never share a commit.
        #expect(zip(blame.runs, blame.runs.dropFirst()).allSatisfy { $0.commitID != $1.commitID })

        let second = blame.runs[2]
        #expect(second.summary == "Second")
        #expect(second.author.name == "Other Person")
        #expect(second.author.email == "other@example.org")
        #expect(second.author.date == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05+01:00"))
        #expect(second.originalPath == "file.txt")
        #expect(blame.runs[1].summary == "First")
    }

    @Test func blameFollowsARename() async throws {
        defer { fixture.remove() }
        let first = try fixture.commit("old.txt", "one\ntwo\nthree\nfour\nfive\n", message: "First")
        try fixture.git("mv", "old.txt", "new.txt")
        try fixture.git("commit", "--quiet", "-m", "Rename")
        let head = try fixture.commit("new.txt", "one\ntwo\nthree\nfour\nfive\nsix\n", message: "Add six")
        let blame = try await fixture.open().blame(of: "new.txt", at: OID(hex: head)!)
        #expect(perLine(blame).map(\.commit) == (try gitBlame("new.txt", at: head)).map(\.commit))
        #expect(blame.runs.first?.commitID.hex == first)
        #expect(blame.runs.first?.originalPath == "old.txt")
    }

    @Test func blameRefusesWhatIsNotText() async throws {
        defer { fixture.remove() }
        try Data([0, 1, 2, 0]).write(to: fixture.url.appending(path: "bin"))
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "-m", "Binary")
        let head = try fixture.git("rev-parse", "HEAD")
        await #expect(throws: GitError.self) { try await fixture.open().blame(of: "bin", at: OID(hex: head)!) }
    }
}
