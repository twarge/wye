import Foundation
import GitKit
import Testing

/// Context lines and whitespace options, compared with `git diff`, and
/// staging from diffs read with them.
@Suite struct DiffOptionTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    private static let thirty = (1...30).map { "line \($0)\n" }.joined()

    /// The hunk headers of a diff, which say how much context it has.
    private func headers(_ diff: FileDiff?) -> [String] {
        diff?.hunks.map { $0.header.components(separatedBy: " @@").first! + " @@" } ?? []
    }

    private func gitHeaders(_ arguments: String...) throws -> [String] {
        try Fixture.run(["diff"] + arguments, in: fixture.url).split(separator: "\n")
            .filter { $0.hasPrefix("@@") }
            .map { $0.components(separatedBy: " @@").first! + " @@" }
    }

    @Test(arguments: [1, 3, 5, 10, 25])
    func readsAsManyContextLinesAsAsked(context: Int) async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", Self.thirty, message: "First")
        try fixture.write(Self.thirty.replacingOccurrences(of: "line 8\n", with: "eight\n")
            .replacingOccurrences(of: "line 20\n", with: "twenty\n"), to: "file.txt")
        let repository = try fixture.open()
        let diff = try await repository.unstagedDiff(of: "file.txt", options: DiffOptions(contextLines: context))
        #expect(headers(diff) == (try fixture.git("diff", "-U\(context)").split(separator: "\n")
            .filter { $0.hasPrefix("@@") }.map { $0.components(separatedBy: " @@").first! + " @@" }))

        try fixture.git("add", "file.txt")
        let staged = try await repository.stagedDiff(of: "file.txt", options: DiffOptions(contextLines: context))
        #expect(headers(staged) == (try gitHeaders("--cached", "-U\(context)")))

        try fixture.git("commit", "--quiet", "-m", "Second")
        let id = try await repository.resolveRevision("HEAD")
        let changes = try await repository.changes(in: id, options: DiffOptions(contextLines: context))
        #expect(headers(changes.first) == (try fixture.git("show", "--format=", "-U\(context)").split(separator: "\n")
            .filter { $0.hasPrefix("@@") }.map { $0.components(separatedBy: " @@").first! + " @@" }))
    }

    @Test(arguments: [
        (DiffOptions.Whitespace.none, ""), (.all, "-w"), (.amount, "-b"), (.endOfLine, "--ignore-space-at-eol")
    ])
    func leavesOutWhitespaceChangesAsGitDoes(whitespace: DiffOptions.Whitespace, flag: String) async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a b\nindented\nend\nkeep\nreal\n", message: "First")
        // An amount change, a new indent, trailing space, and one real change.
        try fixture.write("a  b\n  indented\nend  \nkeep\nREAL\n", to: "file.txt")
        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt", options: DiffOptions(whitespace: whitespace)))

        let arguments = ["diff", "--numstat"] + (flag.isEmpty ? [] : [flag])
        let numstat = try Fixture.run(arguments, in: fixture.url).split(separator: "\t")
        #expect(diff.additions == Int(numstat[0]))
        #expect(diff.deletions == Int(numstat[1]))
    }

    @Test(arguments: [1, 10])
    func stagesAHunkFromADiffWithOtherContext(context: Int) async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", Self.thirty, message: "First")
        try fixture.write(Self.thirty.replacingOccurrences(of: "line 3\n", with: "three\n")
            .replacingOccurrences(of: "line 27\n", with: "twenty-seven\n"), to: "file.txt")
        let repository = try fixture.open()
        let options = DiffOptions(contextLines: context)
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt", options: options))
        #expect(diff.hunks.count == 2)
        try await repository.stage(lines: diff.hunks[1].changedLineIDs, of: diff, options: options)
        #expect(try fixture.git("diff", "--cached").contains("+twenty-seven"))
        #expect(try !fixture.git("diff", "--cached").contains("+three"))

        let staged = try #require(try await repository.stagedDiff(of: "file.txt", options: options))
        try await repository.unstage(lines: staged.changedLineIDs, of: staged, options: options)
        #expect(try fixture.git("diff", "--cached") == "")

        let again = try #require(try await repository.unstagedDiff(of: "file.txt", options: options))
        try await repository.discard(lines: again.hunks[0].changedLineIDs, of: again, options: options)
        #expect(try fixture.workingContent(of: "file.txt") == Self.thirty.replacingOccurrences(of: "line 27\n", with: "twenty-seven\n"))
    }

    @Test func refusesPartsOfADiffThatHidesWhitespace() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\nb\nc\n", message: "First")
        try fixture.write("a \nB\nc\n", to: "file.txt")
        let repository = try fixture.open()
        let options = DiffOptions(whitespace: .all)
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt", options: options))
        await #expect(throws: WorkingCopyError.inexactDiff) {
            try await repository.stage(lines: diff.changedLineIDs, of: diff, options: options)
        }
        await #expect(throws: WorkingCopyError.inexactDiff) {
            try await repository.discard(lines: diff.changedLineIDs, of: diff, options: options)
        }
        #expect(try fixture.git("status", "--porcelain") == "M file.txt")
        #expect(try fixture.workingContent(of: "file.txt") == "a \nB\nc\n")
    }

    @Test func refusesADiffReadWithOtherOptions() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", Self.thirty, message: "First")
        try fixture.write(Self.thirty.replacingOccurrences(of: "line 15\n", with: "fifteen\n"), to: "file.txt")
        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt", options: DiffOptions(contextLines: 1)))
        // Said to be read with three lines, which it was not: its lines need not line up.
        await #expect(throws: WorkingCopyError.diffChanged(path: "file.txt")) {
            try await repository.stage(lines: diff.changedLineIDs.prefix(1).reduce(into: []) { $0.insert($1) }, of: diff)
        }
    }
}
