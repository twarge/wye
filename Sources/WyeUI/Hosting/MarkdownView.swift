import SwiftUI

/// The blocks of a Markdown text, for showing a pull request's description
/// and comments: SwiftUI renders inline Markdown itself, but not headings,
/// lists, quotes or code blocks.
enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A task list's items keep their `[ ]` or `[x]`.
    case list(ordered: Bool, items: [String])
    case quote(String)
    case code(language: String?, text: String)
    case rule

    static func blocks(in text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?
        var quote: [String] = []
        var code: (language: String?, lines: [String])?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if let current = list {
                blocks.append(.list(ordered: current.ordered, items: current.items))
                list = nil
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var current = code {
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    blocks.append(.code(language: current.language, text: current.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    current.lines.append(rawLine)
                    code = current
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = (language.isEmpty ? nil : language, [])
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if let heading = Self.heading(line) {
                flush()
                blocks.append(heading)
                continue
            }
            if ["---", "***", "___"].contains(line.replacingOccurrences(of: " ", with: "")) {
                flush()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix(">") {
                if !paragraph.isEmpty || list != nil { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let (ordered, item) = Self.listItem(line) {
                if !paragraph.isEmpty || !quote.isEmpty || (list != nil && list?.ordered != ordered) { flush() }
                list = (ordered, (list?.items ?? []) + [item])
                continue
            }
            if var current = list, rawLine.hasPrefix("  "), let last = current.items.last {
                // A continuation of the last item.
                current.items[current.items.count - 1] = last + " " + line
                list = current
                continue
            }
            if !quote.isEmpty || list != nil { flush() }
            paragraph.append(line)
        }
        if let current = code {
            blocks.append(.code(language: current.language, text: current.lines.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        var text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (Bool, String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (false, String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 10 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (true, String(rest.dropFirst(2)))
    }
}

/// Markdown as text views: blocks laid out down the page, inline styling
/// and links from SwiftUI.
struct MarkdownView: View {
    var text: String

    var body: some View {
        let blocks = MarkdownBlock.blocks(in: text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .paragraph(let text):
            Self.inline(text)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Self.inline(Self.taskText(item))
                    }
                }
            }
        case .quote(let text):
            Self.inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(width: 3)
                }
        case .code(_, let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.code)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    /// `[x] done` as `☑ done`.
    static func taskText(_ item: String) -> String {
        if item.hasPrefix("[ ] ") { return "☐ " + item.dropFirst(4) }
        if item.lowercased().hasPrefix("[x] ") { return "☑ " + item.dropFirst(4) }
        return item
    }

    static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}
