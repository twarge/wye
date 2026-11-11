import SwiftUI

/// A stretch of a line drawn with a background: a change within the line,
/// or a match of a search. Offsets count Unicode scalars, as tokens do.
struct LineMark: Hashable, Sendable {
    enum Kind: Int, Comparable, Sendable {
        /// The part of a changed line that differs from its counterpart.
        case change
        case match
        /// The match the find bar is on.
        case currentMatch

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var start: Int
    var end: Int
    var kind: Kind
}

/// Draws one line of code as attributed text: tabs laid out, invisibles
/// shown when asked for, tokens in the theme's colours, and marks behind.
struct CodeLineRenderer {
    var tabWidth = 4
    var showsInvisibles = false
    var theme = SyntaxTheme.system
    var scheme = ColorScheme.light
    /// The background of a ``LineMark/Kind/change`` mark: stronger than the
    /// line's own added or removed colour.
    var changeColor = Color.clear

    static let matchColor = Color.yellow.opacity(0.45)
    static let currentMatchColor = Color.orange.opacity(0.75)

    /// The line as text to draw.
    func render(_ line: String, tokens: [SyntaxToken] = [], marks: [LineMark] = []) -> AttributedString {
        if line.isEmpty { return AttributedString(" ") }
        let plain = tokens.isEmpty && marks.isEmpty && !showsInvisibles && !line.contains("\t")
        if plain { return AttributedString(line) }

        var output = AttributedString()
        var pending = ""
        var pendingStyle = Style()
        func flush() {
            guard !pending.isEmpty else { return }
            var piece = AttributedString(pending)
            if pendingStyle.isInvisible {
                piece.foregroundColor = Color.secondary.opacity(0.6)
            } else if let role = pendingStyle.role, let color = theme.color(for: role, in: scheme) {
                piece.foregroundColor = color
            }
            if let mark = pendingStyle.mark {
                piece.backgroundColor = switch mark {
                case .change: changeColor
                case .match: Self.matchColor
                case .currentMatch: Self.currentMatchColor
                }
            }
            output += piece
            pending = ""
        }
        func append(_ text: String, _ style: Style) {
            if style != pendingStyle { flush() }
            pendingStyle = style
            pending += text
        }

        let width = max(1, tabWidth)
        var offset = 0
        var column = 0
        var tokenIndex = 0
        for character in line {
            while tokenIndex < tokens.count, tokens[tokenIndex].end <= offset { tokenIndex += 1 }
            let role = tokenIndex < tokens.count && tokens[tokenIndex].start <= offset ? tokens[tokenIndex].role : nil
            // The strongest mark wins where a match falls in a change.
            let mark = marks.lazy.filter { $0.start <= offset && offset < $0.end }.map(\.kind).max()
            switch character {
            case "\t":
                let span = width - column % width
                if showsInvisibles {
                    append("→" + String(repeating: " ", count: span - 1), Style(mark: mark, isInvisible: true))
                } else {
                    append(String(repeating: " ", count: span), Style(role: role, mark: mark))
                }
                column += span
            case " " where showsInvisibles:
                append("·", Style(mark: mark, isInvisible: true))
                column += 1
            default:
                append(String(character), Style(role: role, mark: mark))
                column += 1
            }
            offset += character.unicodeScalars.count
        }
        flush()
        return output
    }

    private struct Style: Equatable {
        var role: SyntaxRole?
        var mark: LineMark.Kind?
        var isInvisible = false
    }
}
