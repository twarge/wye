import GitKit
import Observation

/// What is drawn over a file's diff lines besides their text: syntax tokens
/// and the parts of changed lines that differ, by line ID.
struct DiffDecorations: Sendable {
    var tokens: [Int: [SyntaxToken]] = [:]
    var changes: [Int: [LineMark]] = [:]

    /// The decorations for a file's diff. Each hunk's old side (unchanged
    /// and removed lines) and new side (unchanged and added lines) is read as
    /// running text, so a comment or string opened on one line colours the
    /// lines after it on its own side.
    static func make(for file: FileDiff) -> DiffDecorations {
        var decorations = DiffDecorations()
        decorations.changes = changeMarks(in: file)
        guard let language = language(for: file) else { return decorations }
        let tokenizer = SyntaxTokenizer(language)
        for hunk in file.hunks {
            // What comes between hunks is unknown, so each starts afresh.
            var old = SyntaxState.normal
            var new = SyntaxState.normal
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    let result = tokenizer.tokenize(line.text, from: new)
                    decorations.tokens[line.id] = result.tokens
                    // The sides only differ after a change opened something.
                    old = old == new ? result.state : tokenizer.tokenize(line.text, from: old).state
                    new = result.state
                case .deletion:
                    let result = tokenizer.tokenize(line.text, from: old)
                    decorations.tokens[line.id] = result.tokens
                    old = result.state
                case .addition:
                    let result = tokenizer.tokenize(line.text, from: new)
                    decorations.tokens[line.id] = result.tokens
                    new = result.state
                case .noNewline:
                    break
                }
            }
        }
        return decorations
    }

    private static func language(for file: FileDiff) -> SyntaxLanguage? {
        let firstLine = file.hunks.first?.lines.first { $0.newNumber == 1 || $0.oldNumber == 1 }?.text
        return SyntaxLanguage.forPath(file.path, firstLine: firstLine)
    }

    /// Pairs each run of removed lines with the added lines straight after
    /// it, line by line, and marks what differs between the two of a pair:
    /// everything between their common start and common end.
    static func changeMarks(in file: FileDiff) -> [Int: [LineMark]] {
        var marks: [Int: [LineMark]] = [:]
        for hunk in file.hunks {
            let lines = hunk.lines
            var index = 0
            while index < lines.count {
                guard lines[index].kind == .deletion else {
                    index += 1
                    continue
                }
                var deletionEnd = index
                while deletionEnd < lines.count, lines[deletionEnd].kind == .deletion { deletionEnd += 1 }
                var additionEnd = deletionEnd
                while additionEnd < lines.count, lines[additionEnd].kind == .addition { additionEnd += 1 }
                let pairs = min(deletionEnd - index, additionEnd - deletionEnd)
                for pair in 0..<pairs {
                    let old = lines[index + pair]
                    let new = lines[deletionEnd + pair]
                    guard let (oldRange, newRange) = differingRanges(old.text, new.text) else { continue }
                    if !oldRange.isEmpty { marks[old.id] = [LineMark(start: oldRange.lowerBound, end: oldRange.upperBound, kind: .change)] }
                    if !newRange.isEmpty { marks[new.id] = [LineMark(start: newRange.lowerBound, end: newRange.upperBound, kind: .change)] }
                }
                index = additionEnd
            }
        }
        return marks
    }

    /// The scalar ranges of `old` and `new` between their common start and
    /// common end; `nil` when the lines share nothing at either end, where
    /// marking the whole line says nothing the background does not.
    static func differingRanges(_ old: String, _ new: String) -> (Range<Int>, Range<Int>)? {
        let a = Array(old.unicodeScalars)
        let b = Array(new.unicodeScalars)
        guard a.count <= SyntaxTokenizer.maximumLineLength, b.count <= SyntaxTokenizer.maximumLineLength else { return nil }
        let limit = min(a.count, b.count)
        var prefix = 0
        while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Leading indentation alone in common is not worth a mark.
        let leading = a.prefix(prefix).allSatisfy { $0 == " " || $0 == "\t" }
        guard !(leading && suffix == 0) else { return nil }
        guard prefix + suffix > 0, a != b else { return nil }
        return (prefix..<(a.count - suffix), prefix..<(b.count - suffix))
    }
}

/// Decorations already worked out, so that coming back to a file does not
/// tokenize it again. An actor, so the work happens off the main actor.
actor SyntaxCache {
    static let shared = SyntaxCache()

    private static let capacity = 48
    /// Files larger than this, in Unicode scalars, are shown without colour.
    static let maximumTextLength = 4_000_000

    private var diffs: [FileDiff: DiffDecorations] = [:]
    private var texts: [TextKey: [[SyntaxToken]]] = [:]
    private var order: [AnyHashable] = []

    private struct TextKey: Hashable {
        var path: String
        var lines: [String]
    }

    func decorations(for file: FileDiff) -> DiffDecorations {
        if let cached = diffs[file] {
            touch(file)
            return cached
        }
        let made = DiffDecorations.make(for: file)
        diffs[file] = made
        touch(file)
        return made
    }

    /// The tokens of each line of a file, or `nil` for a file in no known
    /// language or too large to colour.
    func tokens(for lines: [String], path: String) -> [[SyntaxToken]]? {
        guard let language = SyntaxLanguage.forPath(path, firstLine: lines.first) else { return nil }
        let key = TextKey(path: path, lines: lines)
        if let cached = texts[key] {
            touch(key)
            return cached
        }
        var length = 0
        for line in lines {
            length += line.utf8.count
            if length > Self.maximumTextLength { return nil }
        }
        let made = SyntaxTokenizer(language).tokenize(lines)
        texts[key] = made
        touch(key)
        return made
    }

    private func touch(_ key: AnyHashable) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.capacity {
            let evicted = order.removeFirst()
            if let file = evicted.base as? FileDiff { diffs[file] = nil }
            if let text = evicted.base as? TextKey { texts[text] = nil }
        }
    }
}

/// A view's handle on its decorations: asks the cache when the view shows
/// and publishes the answer when it comes.
@MainActor
@Observable
final class DiffDecorationLoader {
    private(set) var decorations: DiffDecorations?
    @ObservationIgnored private var file: FileDiff?
    @ObservationIgnored private var task: Task<Void, Never>?

    func load(_ file: FileDiff) {
        // Cheap when it is the same diff: arrays compare their storage first.
        guard self.file != file else { return }
        // The old ones would mark the new lines wrongly while these are made.
        decorations = nil
        self.file = file
        task?.cancel()
        task = Task {
            let made = await SyntaxCache.shared.decorations(for: file)
            guard !Task.isCancelled else { return }
            decorations = made
        }
    }
}

/// The same for a whole file's lines, in the file viewer and blame.
@MainActor
@Observable
final class TextSyntaxLoader {
    private(set) var tokens: [[SyntaxToken]]?
    @ObservationIgnored private var key: (path: String, lines: [String])?
    @ObservationIgnored private var task: Task<Void, Never>?

    func load(_ lines: [String], path: String) {
        guard key?.path != path || key?.lines != lines else { return }
        key = (path, lines)
        tokens = nil
        task?.cancel()
        task = Task {
            let made = await SyntaxCache.shared.tokens(for: lines, path: path)
            guard !Task.isCancelled else { return }
            tokens = made
        }
    }

    func tokens(forLine index: Int) -> [SyntaxToken] {
        guard let tokens, tokens.indices.contains(index) else { return [] }
        return tokens[index]
    }
}
