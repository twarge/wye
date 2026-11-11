import Foundation
import GitKit
import Testing
@testable import WyeUI

@Suite struct FindMatchTests {
    private func lines(_ texts: String...) -> [FindLine] {
        texts.enumerated().map { FindLine(row: FindRow(group: "", line: $0.offset), text: $0.element) }
    }

    @Test func findsEveryMatchInOrderWithoutOverlap() {
        let matches = FindModel.matches(of: "aa", in: lines("aaaa", "b", "xaa"), caseSensitive: true)
        #expect(matches == [
            FindMatch(row: FindRow(group: "", line: 0), start: 0, end: 2),
            FindMatch(row: FindRow(group: "", line: 0), start: 2, end: 4),
            FindMatch(row: FindRow(group: "", line: 2), start: 1, end: 3)
        ])
    }

    @Test func caseSensitivity() {
        let source = lines("Let let LET")
        #expect(FindModel.matches(of: "let", in: source, caseSensitive: true).map(\.start) == [4])
        #expect(FindModel.matches(of: "let", in: source, caseSensitive: false).map(\.start) == [0, 4, 8])
    }

    /// Ranges count Unicode scalars, as the tokens they are drawn with do.
    @Test func rangesCountScalars() {
        let matches = FindModel.matches(of: "x", in: lines("é👍🏽 x x"), caseSensitive: true)
        // "é" is one scalar, the thumb with its skin tone two, then a space.
        #expect(matches.map(\.start) == [4, 6])
        #expect(matches.map(\.end) == [5, 7])
    }

    @Test func emptyQueryFindsNothing() {
        #expect(FindModel.matches(of: "", in: lines("abc"), caseSensitive: false).isEmpty)
    }

    @Test func diffLinesAreGroupedByFileAndCaption() {
        let file = FileDiff(
            change: .modified, oldPath: "a", path: "a", isBinary: false, additions: 1, deletions: 0,
            hunks: [FileDiff.Hunk(id: 0, header: "@@", lines: [
                FileDiff.Line(id: 0, kind: .context, oldNumber: 1, newNumber: 1, text: "one"),
                FileDiff.Line(id: 1, kind: .addition, oldNumber: nil, newNumber: 2, text: "two one"),
                FileDiff.Line(id: 2, kind: .noNewline, oldNumber: nil, newNumber: nil, text: "No newline at end of file")
            ])],
            isTruncated: false
        )
        let staged = FindableDiff(file, caption: "Staged").lines
        #expect(staged.map(\.row.line) == [0, 1])
        #expect(staged.first?.row.group != FindableDiff(file, caption: "Unstaged").lines.first?.row.group)
        #expect(FindModel.matches(of: "one", in: staged, caseSensitive: false).map(\.row.line) == [0, 1])
    }

    @MainActor @Test func stepsThroughMatchesAndWraps() {
        let model = FindModel()
        model.present()
        model.query = "a"
        model.set(FindModel.matches(of: "a", in: lines("a a", "a"), caseSensitive: false))
        #expect(model.current == 0)
        #expect(model.status == "1 of 3")
        model.next()
        model.next()
        #expect(model.current == 2)
        model.next()
        #expect(model.current == 0)
        model.previous()
        #expect(model.current == 2)
        let marks = model.marks(for: FindRow(group: "", line: 1))
        #expect(marks == [LineMark(start: 0, end: 1, kind: .currentMatch)])
        #expect(model.marks(for: FindRow(group: "", line: 0)).map(\.kind) == [.match, .match])
        model.dismiss()
        #expect(model.matches.isEmpty)
        #expect(model.marks(for: FindRow(group: "", line: 1)).isEmpty)
    }
}
