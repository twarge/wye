/// What a stretch of source text is, for colouring. Themes give each role a
/// colour; the tokenizer only says which role applies.
enum SyntaxRole: UInt8, CaseIterable, Hashable, Sendable {
    case comment
    case string
    case number
    case keyword
    /// `true`, `nil`, `null` and the like, and character entities in markup.
    case literal
    /// Type names, built in or capitalized.
    case type
    /// Attributes, annotations, decorators and preprocessor directives.
    case attribute
    /// Keys in data files, attribute names in markup, properties in CSS.
    case property
    /// Element names in markup.
    case tag
    /// Shell and Ruby variables.
    case variable
    /// Markdown headings.
    case heading
    /// Markdown emphasis.
    case emphasis
    /// Markdown links.
    case link
}

/// A stretch of one line that has a role. Offsets count Unicode scalars from
/// the start of the line, which is how the tokenizer walks it.
struct SyntaxToken: Hashable, Sendable {
    var start: Int
    var length: Int
    var role: SyntaxRole

    var end: Int { start + length }
}

/// What a line leaves open for the next one: a block comment, a string
/// that runs on, a fenced code block. Lines of a file are tokenized in
/// order, each starting from the state the one before it ended in.
enum SyntaxState: Hashable, Sendable {
    case normal
    /// Inside the language's block comment at this index, nested this deep.
    case comment(Int, depth: Int)
    /// Inside the language's string at this index.
    case string(Int)
    /// Inside a Markdown fenced code block.
    case fence
    /// Inside a markup comment, `<!-- … -->`.
    case markupComment
    /// Inside a markup tag that has not closed yet, among its attributes.
    case markupTag
}
