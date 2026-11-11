import Foundation
import GitKit

/// One way to finish what is being typed in the commit message.
struct CompletionSuggestion: Identifiable, Hashable {
    enum Kind: Hashable {
        case file
        case person
        case issue
        case commit
        case trailer

        var systemImage: String {
            switch self {
            case .file: "doc"
            case .person: "person"
            case .issue: "number"
            case .commit: "arrow.triangle.merge"
            case .trailer: "text.append"
            }
        }
    }

    var kind: Kind
    var title: String
    var detail: String?
    /// What replaces the text being completed.
    var replacement: String

    var id: String { "\(kind)|\(title)|\(replacement)" }
}

/// What the composer's fields can be completed from.
struct CompletionContext {
    /// The changed files' paths.
    var paths: [String] = []
    var sources = CommitCompletionSources()
}

/// Works out completions for the word at the insertion point of a commit
/// message's subject or description. Pure, so it is tested without a window.
enum CommitCompletion {
    static let limit = 8
    static let coAuthorTrailer = "Co-authored-by: "
    /// The prefixes git's `--fixup` and `--squash` give a subject.
    static let fixupPrefixes = ["fixup! ", "squash! ", "amend! "]

    /// The text being completed and what could replace it.
    struct Match: Equatable {
        var range: Range<String.Index>
        var suggestions: [CompletionSuggestion]
    }

    static func match(
        in text: String, at cursor: String.Index, isSubject: Bool, context: CompletionContext
    ) -> Match? {
        guard cursor <= text.endIndex else { return nil }
        let lineStart = text[..<cursor].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
        let line = text[lineStart..<cursor]

        // A fixup's subject names an earlier commit by its subject.
        if isSubject, let prefix = fixupPrefixes.first(where: { line.hasPrefix($0) }) {
            let start = text.index(lineStart, offsetBy: prefix.count)
            let query = String(text[start..<cursor])
            let suggestions = context.sources.subjects
                .filter { query.isEmpty || $0.summary.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                .sorted { lhs, rhs in
                    lhs.summary.lowercased().hasPrefix(query.lowercased()) && !rhs.summary.lowercased().hasPrefix(query.lowercased())
                }
                .filter { $0.summary != String(text[start..<lineEnd]) }
                .prefix(limit)
                .map { CompletionSuggestion(kind: .commit, title: $0.summary, detail: $0.id.abbreviated(), replacement: $0.summary) }
            return suggestions.isEmpty ? nil : Match(range: start..<lineEnd, suggestions: Array(suggestions))
        }

        if !isSubject {
            // After the trailer, the person.
            if line.lowercased().hasPrefix(coAuthorTrailer.lowercased()) {
                let start = text.index(lineStart, offsetBy: coAuthorTrailer.count)
                let query = String(text[start..<cursor]).trimmingCharacters(in: .whitespaces)
                let suggestions = people(matching: query, in: context)
                    .filter { trailerValue($0) != String(text[start..<lineEnd]) }
                    .map { CompletionSuggestion(kind: .person, title: $0.name, detail: $0.email, replacement: trailerValue($0)) }
                return suggestions.isEmpty ? nil : Match(range: start..<lineEnd, suggestions: suggestions)
            }
            // The trailer itself, from its first few letters at a line's start.
            if line.count >= 3, !line.contains(" "), coAuthorTrailer.lowercased().hasPrefix(line.lowercased()),
               line.count < coAuthorTrailer.count {
                return Match(range: lineStart..<cursor, suggestions: [
                    CompletionSuggestion(kind: .trailer, title: "Co-authored-by:", detail: "Credit someone else", replacement: coAuthorTrailer)
                ])
            }
        }

        // Otherwise the word being typed.
        let wordStart = text[lineStart..<cursor].lastIndex(where: { $0.isWhitespace }).map { text.index(after: $0) } ?? lineStart
        var start = wordStart
        // Quotes and brackets before a word are kept.
        while start < cursor, "`'\"([{<".contains(text[start]) { start = text.index(after: start) }
        let word = String(text[start..<cursor])
        guard let first = word.first else { return nil }

        let suggestions: [CompletionSuggestion]
        switch first {
        case "#":
            let digits = word.dropFirst()
            guard digits.allSatisfy(\.isNumber) else { return nil }
            suggestions = context.sources.issues
                .filter { $0.hasPrefix(word) && $0 != word }
                .prefix(limit)
                .map { CompletionSuggestion(kind: .issue, title: $0, detail: nil, replacement: $0) }
        case "@":
            suggestions = people(matching: String(word.dropFirst()), in: context)
                .map { CompletionSuggestion(kind: .person, title: $0.name, detail: $0.email, replacement: $0.name) }
        default:
            guard word.count >= 2 else { return nil }
            suggestions = files(matching: word, in: context)
        }
        return suggestions.isEmpty ? nil : Match(range: start..<cursor, suggestions: suggestions)
    }

    /// Puts a suggestion in place of the text it completes, returning where
    /// the insertion point goes: just after it.
    static func accept(_ suggestion: CompletionSuggestion, in text: inout String, range: Range<String.Index>) -> String.Index {
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        text.replaceSubrange(range, with: suggestion.replacement)
        return text.index(text.startIndex, offsetBy: offset + suggestion.replacement.count)
    }

    static func trailerValue(_ person: GitIdentity) -> String {
        "\(person.name) <\(person.email)>"
    }

    private static func people(matching query: String, in context: CompletionContext) -> [GitIdentity] {
        let query = query.lowercased()
        return Array(context.sources.people.filter { person in
            query.isEmpty || person.name.lowercased().contains(query) || person.email.lowercased().contains(query)
        }
        .prefix(limit))
    }

    /// Files whose name starts with the word complete to the name; files
    /// whose path does, to the path.
    private static func files(matching word: String, in context: CompletionContext) -> [CompletionSuggestion] {
        let query = word.lowercased()
        var byName: [CompletionSuggestion] = []
        var byPath: [CompletionSuggestion] = []
        var seen: Set<String> = []
        for path in context.paths {
            let name = path.splitPath.name
            if name.lowercased().hasPrefix(query), name != word, seen.insert(name).inserted {
                byName.append(CompletionSuggestion(kind: .file, title: name, detail: path == name ? nil : path, replacement: name))
            } else if path.lowercased().hasPrefix(query), path != word, seen.insert(path).inserted {
                byPath.append(CompletionSuggestion(kind: .file, title: path, detail: nil, replacement: path))
            }
        }
        return Array((byName + byPath).prefix(limit))
    }
}
