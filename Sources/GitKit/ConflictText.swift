import Foundation

/// A conflicted text file as a three-way merge sees it: runs of lines that
/// merged by themselves, between conflicts where both sides changed the same
/// lines.
///
/// Lines keep their own endings ("\n", "\r\n", or none for a last line
/// without one), so joining them gives back the bytes exactly.
public struct MergeText: Hashable, Sendable {
    public enum Region: Hashable, Sendable {
        /// Lines that are the same on both sides, or that one side changed
        /// alone, as the merge already took them.
        case merged([String])
        case conflict(TextConflict)
    }

    public let regions: [Region]
    /// The line ending the file mostly uses, for lines Wye has to end
    /// itself, such as text typed by hand.
    public let lineEnding: String

    public init(regions: [Region], lineEnding: String) {
        self.regions = regions
        self.lineEnding = lineEnding
    }

    /// The conflicts, in file order.
    public var conflicts: [TextConflict] {
        regions.compactMap {
            if case .conflict(let conflict) = $0 { conflict } else { nil }
        }
    }

    /// The file with each conflict resolved as `resolutions` says, by the
    /// conflict's position. `nil` if any is unresolved.
    public func merged(_ resolutions: [Int: ConflictResolution]) -> String? {
        var text = ""
        var position = 0
        for region in regions {
            switch region {
            case .merged(let lines):
                text += lines.joined()
            case .conflict(let conflict):
                guard let resolution = resolutions[position] else { return nil }
                text += conflict.lines(resolvedBy: resolution, lineEnding: lineEnding).joined()
                position += 1
            }
        }
        return text
    }
}

/// Where both sides changed the same lines.
public struct TextConflict: Hashable, Sendable {
    /// The lines as they were in the common ancestor. Empty when both sides
    /// added the file, or added lines where there were none.
    public let base: [String]
    public let ours: [String]
    public let theirs: [String]
    /// Whether the conflict runs to the end of the file, where a line may
    /// have no ending.
    public let isAtEnd: Bool

    public init(base: [String], ours: [String], theirs: [String], isAtEnd: Bool) {
        self.base = base
        self.ours = ours
        self.theirs = theirs
        self.isAtEnd = isAtEnd
    }

    /// The lines that replace the conflict.
    public func lines(resolvedBy resolution: ConflictResolution, lineEnding: String) -> [String] {
        switch resolution {
        case .ours: ours
        case .theirs: theirs
        case .base: base
        case .oursThenTheirs: Self.join(ours, theirs, lineEnding: lineEnding)
        case .theirsThenOurs: Self.join(theirs, ours, lineEnding: lineEnding)
        case .edited(let text): edited(text, lineEnding: lineEnding)
        }
    }

    /// One block after the other. A block whose last line has no ending, at
    /// the end of the file, gets one so the next does not run on from it.
    private static func join(_ first: [String], _ second: [String], lineEnding: String) -> [String] {
        guard var last = first.last, !second.isEmpty else { return first + second }
        if !last.hasLineEnding {
            last += lineEnding
        }
        return first.dropLast() + [last] + second
    }

    /// Text typed by hand, which an editor gives with "\n" endings, in the
    /// file's own endings. Each line ends, so the text after it starts on a
    /// line of its own, except at the end of a file whose sides both had no
    /// final line ending.
    private func edited(_ text: String, lineEnding: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        let keepsLastOpen = !endsWithNewline && isAtEnd
            && [ours.last, theirs.last].allSatisfy { $0.map { !$0.hasLineEnding } ?? true }
        return lines.enumerated().map { position, line in
            position == lines.count - 1 && keepsLastOpen ? line : line + lineEnding
        }
    }
}

/// How one conflict is settled.
public enum ConflictResolution: Hashable, Sendable {
    case ours
    case theirs
    /// The ancestor's lines, dropping both sides' changes.
    case base
    case oursThenTheirs
    case theirsThenOurs
    /// Text written by hand.
    case edited(String)
}

extension String {
    /// Whether the line ends with "\n" (and so also "\r\n").
    var hasLineEnding: Bool {
        unicodeScalars.last == "\n"
    }

    /// The line without its ending, for showing.
    public var withoutLineEnding: String {
        var scalars = unicodeScalars
        if scalars.last == "\n" { scalars.removeLast() }
        if scalars.last == "\r" { scalars.removeLast() }
        return String(scalars)
    }
}

// MARK: Reading libgit2's output

extension MergeText {
    /// Reads the diff3-style output of a file merge into regions. `markerSize`
    /// is the length of the markers it was written with, chosen longer than
    /// any run of marker characters starting a line of the input, so content
    /// cannot be mistaken for one. `sidesEndOpen` says, for base, ours and
    /// theirs, whether the file's last line has no ending: the merge ends a
    /// conflict's lines before its closing marker, so that is put back.
    static func parse(
        _ output: [UInt8], markerSize: Int, sidesEndOpen: (base: Bool, ours: Bool, theirs: Bool)
    ) -> MergeText {
        enum State { case merged, ours, base, theirs }
        let lines = splitLines(output)
        var regions: [Region] = []
        var merged: [String] = []
        var ours: [String] = [], base: [String] = [], theirs: [String] = []
        var state = State.merged

        func isMarker(_ line: [UInt8], _ character: UInt8) -> Bool {
            guard line.count >= markerSize, line.prefix(markerSize).allSatisfy({ $0 == character }) else { return false }
            guard line.count > markerSize else { return true }
            return [UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n")].contains(line[markerSize])
        }

        for line in lines {
            switch state {
            case .merged:
                if isMarker(line, UInt8(ascii: "<")) {
                    if !merged.isEmpty { regions.append(.merged(merged)) }
                    merged = []
                    state = .ours
                } else {
                    merged.append(String(decoding: line, as: UTF8.self))
                }
            case .ours:
                if isMarker(line, UInt8(ascii: "|")) {
                    state = .base
                } else if isMarker(line, UInt8(ascii: "=")) {
                    state = .theirs
                } else {
                    ours.append(String(decoding: line, as: UTF8.self))
                }
            case .base:
                if isMarker(line, UInt8(ascii: "=")) {
                    state = .theirs
                } else {
                    base.append(String(decoding: line, as: UTF8.self))
                }
            case .theirs:
                if isMarker(line, UInt8(ascii: ">")) {
                    regions.append(.conflict(TextConflict(base: base, ours: ours, theirs: theirs, isAtEnd: false)))
                    ours = []; base = []; theirs = []
                    state = .merged
                } else {
                    theirs.append(String(decoding: line, as: UTF8.self))
                }
            }
        }
        if !merged.isEmpty { regions.append(.merged(merged)) }

        // A conflict with nothing after it holds each side's last line.
        if case .conflict(let last) = regions.last {
            regions[regions.count - 1] = .conflict(TextConflict(
                base: sidesEndOpen.base ? openingLastLine(last.base) : last.base,
                ours: sidesEndOpen.ours ? openingLastLine(last.ours) : last.ours,
                theirs: sidesEndOpen.theirs ? openingLastLine(last.theirs) : last.theirs,
                isAtEnd: true
            ))
        }
        return MergeText(regions: regions, lineEnding: dominantLineEnding(in: lines))
    }

    /// Lines with their endings. A last line without one is kept as it is.
    static func splitLines(_ bytes: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var start = 0
        for (position, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
            lines.append(Array(bytes[start...position]))
            start = position + 1
        }
        if start < bytes.count {
            lines.append(Array(bytes[start...]))
        }
        return lines
    }

    /// The longest run of one marker character at the start of any line.
    static func longestMarkerRun(in contents: [[UInt8]]) -> Int {
        let markers: Set<UInt8> = [UInt8(ascii: "<"), UInt8(ascii: "|"), UInt8(ascii: "="), UInt8(ascii: ">")]
        var longest = 0
        for content in contents {
            for line in splitLines(content) {
                guard let first = line.first, markers.contains(first) else { continue }
                longest = max(longest, line.prefix { $0 == first }.count)
            }
        }
        return longest
    }

    private static func openingLastLine(_ lines: [String]) -> [String] {
        guard let last = lines.last else { return lines }
        return lines.dropLast() + [last.withoutLineEnding]
    }

    private static func dominantLineEnding(in lines: [[UInt8]]) -> String {
        var crlf = 0, lf = 0
        for line in lines where line.last == UInt8(ascii: "\n") {
            if line.count >= 2 && line[line.count - 2] == UInt8(ascii: "\r") { crlf += 1 } else { lf += 1 }
        }
        return crlf > lf ? "\r\n" : "\n"
    }
}
