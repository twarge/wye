/// Splits lines of source into coloured stretches, a line at a time, carrying
/// open comments and strings from each line to the next.
///
/// It is a small hand-written scanner over the language's data rather than
/// a parser: fast enough to run over a whole file in a moment, and wrong
/// only in ways that cost a colour, never a line.
struct SyntaxTokenizer: Sendable {
    let language: SyntaxLanguage

    /// Lines longer than this are left plain: they are minified or generated,
    /// and colouring them would cost more than it gives.
    static let maximumLineLength = 2_000

    init(_ language: SyntaxLanguage) {
        self.language = language
    }

    /// The tokens of each line, the lines read in order as one text.
    func tokenize(_ lines: [String]) -> [[SyntaxToken]] {
        var state = SyntaxState.normal
        return lines.map { line in
            let result = tokenize(line, from: state)
            state = result.state
            return result.tokens
        }
    }

    /// One line's tokens, and the state the next line starts in.
    func tokenize(_ line: String, from state: SyntaxState) -> (tokens: [SyntaxToken], state: SyntaxState) {
        let text = Array(line.unicodeScalars)
        guard text.count <= Self.maximumLineLength else { return ([], state) }
        var scanner = LineScanner(text: text, language: language)
        let end: SyntaxState = switch language.grammar {
        case .code: scanner.scanCode(from: state)
        case .markdown: scanner.scanMarkdown(from: state)
        case .markup: scanner.scanMarkup(from: state)
        }
        return (scanner.tokens, end)
    }
}

/// The scan of one line.
private struct LineScanner {
    let text: [Unicode.Scalar]
    let language: SyntaxLanguage
    var tokens: [SyntaxToken] = []
    var index = 0

    init(text: [Unicode.Scalar], language: SyntaxLanguage) {
        self.text = text
        self.language = language
    }

    var count: Int { text.count }

    // MARK: Helpers

    func matches(_ pattern: [Unicode.Scalar], at position: Int) -> Bool {
        guard position + pattern.count <= count else { return false }
        for offset in pattern.indices where text[position + offset] != pattern[offset] {
            return false
        }
        return true
    }

    func find(_ pattern: [Unicode.Scalar], from position: Int) -> Int? {
        var position = position
        while position + pattern.count <= count {
            if matches(pattern, at: position) { return position }
            position += 1
        }
        return nil
    }

    mutating func emit(_ start: Int, _ end: Int, _ role: SyntaxRole) {
        guard end > start else { return }
        // Neighbours of one role merge, which keeps lines of comment one token.
        if let last = tokens.last, last.role == role, last.end == start {
            tokens[tokens.count - 1].length += end - start
        } else {
            tokens.append(SyntaxToken(start: start, length: end - start, role: role))
        }
    }

    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar.properties.isWhitespace
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || (scalar.value > 0x7F && scalar.properties.isAlphabetic)
    }

    func isWordStart(_ scalar: Unicode.Scalar) -> Bool {
        Self.isLetter(scalar) || scalar == "_" || (scalar == "$" && language.wordCharacters.contains("$"))
    }

    func isWordPart(_ scalar: Unicode.Scalar) -> Bool {
        Self.isLetter(scalar) || Self.isDigit(scalar) || scalar == "_" || language.wordCharacters.contains(scalar)
    }

    func wordEnd(from position: Int) -> Int {
        var end = position
        while end < count, isWordPart(text[end]) { end += 1 }
        return end
    }

    /// Whether only spaces come before `position` on the line.
    func startsLine(_ position: Int) -> Bool {
        text[..<position].allSatisfy(Self.isSpace)
    }

    // MARK: Code

    mutating func scanCode(from state: SyntaxState) -> SyntaxState {
        switch state {
        case .comment(let rule, let depth):
            if let open = resumeComment(rule, depth: depth, from: 0) { return open }
        case .string(let rule):
            if let open = resumeString(rule, start: 0, from: 0) { return open }
        default:
            break
        }

        while index < count {
            let scalar = text[index]
            if Self.isSpace(scalar) {
                index += 1
                continue
            }
            if language.preprocessor, scalar == "#", startsLine(index) {
                var end = index + 1
                while end < count, Self.isSpace(text[end]) { end += 1 }
                end = wordEnd(from: end)
                emit(index, end, .attribute)
                index = end
                continue
            }
            if isLineComment(at: index) {
                emit(index, count, .comment)
                return .normal
            }
            if let rule = language.blockComments.firstIndex(where: { matches($0.open, at: index) }) {
                let start = index
                index += language.blockComments[rule].open.count
                emit(start, index, .comment)
                if let open = resumeComment(rule, depth: 1, from: index) { return open }
                continue
            }
            if let rule = stringRule(at: index) {
                let start = index
                index += language.strings[rule].open.count
                if let open = resumeString(rule, start: start, from: index) { return open }
                // A string that is a key, as in JSON, is coloured as one.
                if isKey(start: start, end: index), let last = tokens.indices.last {
                    tokens[last].role = .property
                }
                continue
            }
            if language.characterLiterals, scalar == "'" {
                scanCharacterLiteral()
                continue
            }
            if Self.isDigit(scalar) {
                let end = numberEnd(from: index)
                emit(index, end, .number)
                index = end
                continue
            }
            if language.attributePrefixes.contains(scalar), index + 1 < count {
                let next = text[index + 1]
                if isWordStart(next) {
                    let end = wordEnd(from: index + 1)
                    emit(index, end, .attribute)
                    index = end
                    continue
                }
                if next == "[", let close = find(["]"], from: index + 2) {
                    emit(index, close + 1, .attribute)
                    index = close + 1
                    continue
                }
            }
            if language.variablePrefixes.contains(scalar), let end = variableEnd(from: index) {
                emit(index, end, .variable)
                index = end
                continue
            }
            if isWordStart(scalar) || (scalar == "!" && language.keywords.contains("!important")) {
                scanWord()
                continue
            }
            index += 1
        }
        return .normal
    }

    func isLineComment(at position: Int) -> Bool {
        guard language.lineComments.contains(where: { matches($0, at: position) }) else { return false }
        return !language.commentNeedsSpace || position == 0 || Self.isSpace(text[position - 1])
    }

    func stringRule(at position: Int) -> Int? {
        language.strings.firstIndex { rule in
            guard matches(rule.open, at: position) else { return false }
            // `r"` and `b"` open strings only where a word does not run into them.
            if let first = rule.open.first, Self.isLetter(first), position > 0, isWordPart(text[position - 1]) {
                return false
            }
            return true
        }
    }

    /// Scans the rest of a block comment from `position`. Returns the state
    /// to carry on with when the comment runs past the line.
    mutating func resumeComment(_ rule: Int, depth: Int, from position: Int) -> SyntaxState? {
        let comment = language.blockComments[rule]
        var depth = depth
        var scan = position
        while scan < count {
            if matches(comment.close, at: scan) {
                scan += comment.close.count
                depth -= 1
                if depth == 0 {
                    emit(position, scan, .comment)
                    index = scan
                    return nil
                }
            } else if comment.nests, matches(comment.open, at: scan) {
                scan += comment.open.count
                depth += 1
            } else {
                scan += 1
            }
        }
        emit(position, count, .comment)
        index = count
        return .comment(rule, depth: depth)
    }

    /// Scans the rest of a string from `position`, the string having begun at
    /// `start`. Returns the state to carry on with when it runs past the line.
    mutating func resumeString(_ rule: Int, start: Int, from position: Int) -> SyntaxState? {
        let string = language.strings[rule]
        var scan = position
        while scan < count {
            if string.escapes, text[scan] == "\\" {
                scan += 2
                continue
            }
            if matches(string.close, at: scan) {
                scan += string.close.count
                emit(start, scan, .string)
                index = scan
                return nil
            }
            scan += 1
        }
        emit(start, count, .string)
        index = count
        // A string that may not run on ends with its line.
        return string.multiline ? .string(rule) : .normal
    }

    /// Rust's `'a'` and `'\n'`, told from a lifetime such as `'a`.
    mutating func scanCharacterLiteral() {
        if index + 1 < count, text[index + 1] == "\\", let close = find(["'"], from: index + 2), close - index <= 12 {
            emit(index, close + 1, .string)
            index = close + 1
        } else if index + 2 < count, text[index + 2] == "'" {
            emit(index, index + 3, .string)
            index += 3
        } else {
            let end = wordEnd(from: index + 1)
            emit(index, end, .attribute)
            index = max(end, index + 1)
        }
    }

    func numberEnd(from position: Int) -> Int {
        var end = position
        if text[end] == "0", end + 1 < count, "xXbBoO".unicodeScalars.contains(text[end + 1]) {
            end += 2
            while end < count, isWordPart(text[end]) { end += 1 }
            return end
        }
        var seenPoint = false
        while end < count {
            let scalar = text[end]
            if scalar == "e" || scalar == "E", end + 1 < count, text[end + 1] == "+" || text[end + 1] == "-" {
                end += 2
            } else if Self.isLetter(scalar) || Self.isDigit(scalar) || scalar == "_" {
                end += 1
            } else if scalar == ".", !seenPoint, end + 1 < count, Self.isDigit(text[end + 1]) {
                seenPoint = true
                end += 1
            } else {
                break
            }
        }
        return end
    }

    /// Where a variable such as `$HOME`, `${name}`, `$1` or `@count` ends.
    func variableEnd(from position: Int) -> Int? {
        guard position + 1 < count else { return nil }
        let next = text[position + 1]
        if next == "{", let close = find(["}"], from: position + 2) { return close + 1 }
        if isWordStart(next) {
            var end = position + 1
            // `-` is part of words in shell, but not of its variables.
            while end < count, Self.isLetter(text[end]) || Self.isDigit(text[end]) || text[end] == "_" { end += 1 }
            return end
        }
        if text[position] == "$", Self.isDigit(next) || "@#?$!*-".unicodeScalars.contains(next) {
            return position + 2
        }
        return nil
    }

    mutating func scanWord() {
        let start = index
        let end = text[index] == "!" ? wordEnd(from: index + 1) : wordEnd(from: index)
        index = max(end, start + 1)
        if isKey(start: start, end: index) {
            emit(start, index, .property)
            return
        }
        var word = String(String.UnicodeScalarView(text[start..<index]))
        if language.ignoresCase { word = word.lowercased() }
        if language.keywords.contains(word) {
            emit(start, index, .keyword)
        } else if language.literals.contains(word) {
            emit(start, index, .literal)
        } else if language.types.contains(word) {
            emit(start, index, .type)
        } else if language.capitalizedTypes, text[start].properties.isUppercase,
                  text[start..<index].contains(where: \.properties.isLowercase) {
            // `MAX_COUNT` stays plain: a type has small letters too.
            emit(start, index, .type)
        }
    }

    /// Whether the word or string from `start` to `end` is followed by a key
    /// separator, and so is a key.
    func isKey(start: Int, end: Int) -> Bool {
        guard !language.keySeparators.isEmpty else { return false }
        var after = end
        while after < count, Self.isSpace(text[after]) { after += 1 }
        var isKey = after < count && language.keySeparators.contains(text[after])
        if isKey, language.keysStartLines {
            // Before a key only spaces, or YAML's list dash.
            isKey = text[..<start].allSatisfy { Self.isSpace($0) || $0 == "-" }
            // YAML and CSS need a space after the colon: `a:hover` is no key.
            if isKey, text[after] == ":", after + 1 < count {
                isKey = Self.isSpace(text[after + 1])
            }
        }
        return isKey
    }

    // MARK: Markdown

    mutating func scanMarkdown(from state: SyntaxState) -> SyntaxState {
        var start = 0
        while start < count, start < 4, Self.isSpace(text[start]) { start += 1 }
        let isFence = matches(Array("```".unicodeScalars), at: start) || matches(Array("~~~".unicodeScalars), at: start)
        switch state {
        case .fence:
            emit(0, count, .string)
            return isFence ? .normal : .fence
        case .markupComment:
            guard let close = find(Array("-->".unicodeScalars), from: 0) else {
                emit(0, count, .comment)
                return .markupComment
            }
            emit(0, close + 3, .comment)
            index = close + 3
        default:
            index = start
            if isFence {
                emit(0, count, .string)
                return .fence
            }
            if start < count, text[start] == "#" {
                var level = start
                while level < count, text[level] == "#" { level += 1 }
                if level - start <= 6, level == count || Self.isSpace(text[level]) {
                    emit(start, count, .heading)
                    return .normal
                }
            }
            if start < count, text[start] == ">" {
                emit(start, count, .comment)
                return .normal
            }
            scanListMarker(from: start)
        }
        return scanMarkdownInline()
    }

    /// A list's `-`, `*`, `+` or `1.`, or a rule such as `---`.
    mutating func scanListMarker(from start: Int) {
        guard start < count else { return }
        let first = text[start]
        if "-*_".unicodeScalars.contains(first) {
            let rest = text[start...].filter { !Self.isSpace($0) }
            if rest.count >= 3, rest.allSatisfy({ $0 == first }) {
                emit(start, count, .keyword)
                index = count
                return
            }
        }
        if "-*+".unicodeScalars.contains(first), start + 1 < count, Self.isSpace(text[start + 1]) {
            emit(start, start + 1, .keyword)
            index = start + 1
            return
        }
        var end = start
        while end < count, Self.isDigit(text[end]) { end += 1 }
        if end > start, end + 1 < count, text[end] == "." || text[end] == ")", Self.isSpace(text[end + 1]) {
            emit(start, end + 1, .keyword)
            index = end + 1
        }
    }

    mutating func scanMarkdownInline() -> SyntaxState {
        while index < count {
            let scalar = text[index]
            switch scalar {
            case "\\":
                index += 2
            case "`":
                var run = index
                while run < count, text[run] == "`" { run += 1 }
                let fence = Array(repeating: Unicode.Scalar("`"), count: run - index)
                if let close = find(fence, from: run) {
                    emit(index, close + fence.count, .string)
                    index = close + fence.count
                } else {
                    index = run
                }
            case "<" where matches(Array("<!--".unicodeScalars), at: index):
                guard let close = find(Array("-->".unicodeScalars), from: index + 4) else {
                    emit(index, count, .comment)
                    return .markupComment
                }
                emit(index, close + 3, .comment)
                index = close + 3
            case "*", "_":
                scanEmphasis(scalar)
            case "[":
                scanLink()
            case "!" where index + 1 < count && text[index + 1] == "[":
                scanLink()
            default:
                index += 1
            }
        }
        return .normal
    }

    mutating func scanEmphasis(_ marker: Unicode.Scalar) {
        // `snake_case` words are not emphasis.
        if marker == "_", index > 0, isWordPart(text[index - 1]) {
            index += 1
            return
        }
        let width = index + 1 < count && text[index + 1] == marker ? 2 : 1
        let open = index + width
        guard open < count, !Self.isSpace(text[open]) else {
            index += width
            return
        }
        let close = Array(repeating: marker, count: width)
        var scan = open + 1
        while let found = find(close, from: scan) {
            if !Self.isSpace(text[found - 1]) {
                emit(index, found + width, .emphasis)
                index = found + width
                return
            }
            scan = found + 1
        }
        index += width
    }

    mutating func scanLink() {
        let start = index
        let open = text[index] == "!" ? index + 1 : index
        guard let close = find(["]"], from: open + 1) else {
            index = open + 1
            return
        }
        var end = close + 1
        if end < count, text[end] == "(", let paren = find([")"], from: end + 1) {
            end = paren + 1
        } else if end < count, text[end] == "[", let bracket = find(["]"], from: end + 1) {
            end = bracket + 1
        } else if !(end < count && text[end] == ":") {
            index = open + 1
            return
        }
        emit(start, end, .link)
        index = end
    }

    // MARK: Markup

    mutating func scanMarkup(from state: SyntaxState) -> SyntaxState {
        switch state {
        case .markupComment:
            if let open = resumeMarkupComment(start: 0) { return open }
        case .markupTag:
            if let open = scanTagInside() { return open }
        default:
            break
        }
        while index < count {
            let scalar = text[index]
            if scalar == "<", matches(Array("<!--".unicodeScalars), at: index) {
                let start = index
                index += 4
                if let open = resumeMarkupComment(start: start) { return open }
            } else if scalar == "<", index + 1 < count,
                      Self.isLetter(text[index + 1]) || "/!?".unicodeScalars.contains(text[index + 1]) {
                let start = index
                index += 1
                if "/!?".unicodeScalars.contains(text[index]) { index += 1 }
                while index < count, isMarkupNamePart(text[index]) { index += 1 }
                emit(start, index, .tag)
                if let open = scanTagInside() { return open }
            } else if scalar == "&", let semicolon = find([";"], from: index + 1), semicolon - index <= 10,
                      text[(index + 1)..<semicolon].allSatisfy({ isMarkupNamePart($0) || $0 == "#" }) {
                emit(index, semicolon + 1, .literal)
                index = semicolon + 1
            } else {
                index += 1
            }
        }
        return .normal
    }

    func isMarkupNamePart(_ scalar: Unicode.Scalar) -> Bool {
        Self.isLetter(scalar) || Self.isDigit(scalar) || "-_:.".unicodeScalars.contains(scalar)
    }

    mutating func resumeMarkupComment(start: Int) -> SyntaxState? {
        guard let close = find(Array("-->".unicodeScalars), from: index) else {
            emit(start, count, .comment)
            index = count
            return .markupComment
        }
        emit(start, close + 3, .comment)
        index = close + 3
        return nil
    }

    /// A tag's attributes, up to its `>`. Returns the state to carry on with
    /// when the tag runs past the line.
    mutating func scanTagInside() -> SyntaxState? {
        while index < count {
            let scalar = text[index]
            if scalar == ">" {
                emit(index, index + 1, .tag)
                index += 1
                return nil
            }
            if (scalar == "/" || scalar == "?"), index + 1 < count, text[index + 1] == ">" {
                emit(index, index + 2, .tag)
                index += 2
                return nil
            }
            if scalar == "\"" || scalar == "'" {
                let close = find([scalar], from: index + 1).map { $0 + 1 } ?? count
                emit(index, close, .string)
                index = close
            } else if isMarkupNamePart(scalar) {
                let start = index
                while index < count, isMarkupNamePart(text[index]) { index += 1 }
                emit(start, index, .property)
            } else {
                index += 1
            }
        }
        return .markupTag
    }
}
