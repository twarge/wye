import GitKit
import Observation
import SwiftUI

/// A line that find can reach: which list of lines it is in (a file's diff,
/// or `""` for a file shown whole) and its ID or index there. Rows carry it
/// as their scroll ID, so find can bring a match into view.
struct FindRow: Hashable, Sendable {
    var group: String
    var line: Int

    /// The group of a file's diff, told apart from the same file's other
    /// diff by its caption ("Staged", "Unstaged").
    static func group(for file: FileDiff, caption: String?) -> String {
        "\(caption ?? "")\u{1F}\(file.id)"
    }
}

/// A line's text, for searching.
struct FindLine: Sendable {
    var row: FindRow
    var text: String
}

/// One match: a stretch of a line, in Unicode scalars.
struct FindMatch: Hashable, Sendable {
    var row: FindRow
    var start: Int
    var end: Int
}

/// A diff to search, as ``FileDiffView`` shows it.
struct FindableDiff: Equatable, Sendable {
    var file: FileDiff
    var caption: String?

    init(_ file: FileDiff, caption: String? = nil) {
        self.file = file
        self.caption = caption
    }

    var lines: [FindLine] {
        let group = FindRow.group(for: file, caption: caption)
        return file.hunks.flatMap(\.lines).compactMap { line in
            line.kind == .noNewline ? nil : FindLine(row: FindRow(group: group, line: line.id), text: line.text)
        }
    }
}

/// The find bar's state for one diff or file: what is looked for, the
/// matches, and which of them is current.
@MainActor
@Observable
final class FindModel {
    var isPresented = false
    var query = ""
    var isCaseSensitive = false
    private(set) var matches: [FindMatch] = []
    /// The index in `matches` of the match being shown.
    private(set) var current: Int?
    /// Goes up each time a match should be scrolled to.
    private(set) var scrollRequests = 0
    /// Goes up each time the field should take focus.
    private(set) var focusRequests = 0

    @ObservationIgnored private var byRow: [FindRow: [Int]] = [:]

    /// Opens the bar, or puts focus back in its field.
    func present() {
        isPresented = true
        focusRequests += 1
    }

    func dismiss() {
        isPresented = false
        set([])
    }

    func next() { step(by: 1) }

    func previous() { step(by: -1) }

    private func step(by offset: Int) {
        if !isPresented { present() }
        guard !matches.isEmpty else { return }
        current = ((current ?? (offset > 0 ? -1 : 0)) + offset + matches.count) % matches.count
        scrollRequests += 1
    }

    var currentMatch: FindMatch? {
        current.map { matches[$0] }
    }

    /// "3 of 12", or why there is nothing to step through.
    var status: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return "No matches" }
        guard let current else { return matches.count == 1 ? "1 match" : "\(matches.count.formatted()) matches" }
        return "\((current + 1).formatted()) of \(matches.count.formatted())"
    }

    /// Takes new matches, staying on the match nearest the one shown.
    func set(_ matches: [FindMatch]) {
        let previous = currentMatch
        self.matches = matches
        byRow = Dictionary(grouping: matches.indices, by: { matches[$0].row })
        if matches.isEmpty {
            current = nil
        } else if let previous, let same = matches.firstIndex(where: { $0.row == previous.row && $0.start >= previous.start }) {
            current = same
        } else {
            current = 0
            scrollRequests += 1
        }
    }

    /// The marks to draw on a row: its matches, the current one set apart.
    func marks(for row: FindRow) -> [LineMark] {
        guard isPresented, let indices = byRow[row] else { return [] }
        return indices.map { index in
            let match = matches[index]
            return LineMark(start: match.start, end: match.end, kind: index == current ? .currentMatch : .match)
        }
    }

    /// Every match of `query` in `lines`, in order, none overlapping.
    nonisolated static func matches(of query: String, in lines: [FindLine], caseSensitive: Bool) -> [FindMatch] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = caseSensitive ? [.literal] : [.caseInsensitive]
        var matches: [FindMatch] = []
        for line in lines {
            let text = line.text
            var searchStart = text.startIndex
            var scalarOffset = 0
            var offsetIndex = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: query, options: options, range: searchStart..<text.endIndex) {
                // Count scalars on from the last match rather than from the start.
                scalarOffset += text.unicodeScalars[offsetIndex..<range.lowerBound].count
                let length = text.unicodeScalars[range].count
                matches.append(FindMatch(row: line.row, start: scalarOffset, end: scalarOffset + length))
                scalarOffset += length
                offsetIndex = range.upperBound
                searchStart = range.isEmpty ? text.index(after: range.upperBound) : range.upperBound
            }
        }
        return matches
    }
}

extension FocusedValues {
    /// The find bar of the diff or file that has focus, for the Edit menu.
    @Entry var findModel: FindModel?
}
