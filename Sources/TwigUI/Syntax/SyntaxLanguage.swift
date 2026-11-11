import Foundation

/// How one language is coloured, as data: its comments, strings, words and
/// the few shapes worth picking out. One tokenizer reads every language
/// described this way; Markdown and markup have small ones of their own.
struct SyntaxLanguage: Sendable {
    enum Grammar: Sendable {
        /// Code and data files, read by ``SyntaxTokenizer``'s general rules.
        case code
        case markdown
        /// HTML, XML and the like.
        case markup
    }

    struct BlockComment: Sendable {
        var open: [Unicode.Scalar]
        var close: [Unicode.Scalar]
        /// Whether a comment opened inside one needs its own close, as in Swift and Rust.
        var nests = false
    }

    struct StringRule: Sendable {
        var open: [Unicode.Scalar]
        var close: [Unicode.Scalar]
        /// Whether a backslash escapes the next character.
        var escapes = true
        /// Whether the string may run onto following lines.
        var multiline = false
    }

    var name: String
    var grammar = Grammar.code
    var lineComments: [[Unicode.Scalar]] = []
    var blockComments: [BlockComment] = []
    /// Longest opening first, so `"""` is tried before `"`.
    var strings: [StringRule] = []
    var keywords: Set<String> = []
    var literals: Set<String> = []
    var types: Set<String> = []
    /// Whether words match keywords whatever their case, as in SQL.
    var ignoresCase = false
    /// Whether a word starting with a capital and having a small letter is a type.
    var capitalizedTypes = false
    /// Characters that make the word after them an attribute: `@` in Swift and Java.
    var attributePrefixes: Set<Unicode.Scalar> = []
    /// Characters that make the word after them a variable: `$` in shell.
    var variablePrefixes: Set<Unicode.Scalar> = []
    /// Whether `#` starting a line begins a preprocessor directive, as in C.
    var preprocessor = false
    /// Characters that, after a word or string, make it a key: `:` in JSON.
    var keySeparators: Set<Unicode.Scalar> = []
    /// Whether keys are only picked out at the start of a line, as in TOML and YAML.
    var keysStartLines = false
    /// Characters besides letters, digits and `_` that words may hold.
    var wordCharacters: Set<Unicode.Scalar> = []
    /// Whether a line comment needs a space or the line's start before it, so
    /// that `$#` in shell or `a#b` in YAML is not one.
    var commentNeedsSpace = false
    /// Rust's `'a'` characters beside its `'a` lifetimes.
    var characterLiterals = false

    init(_ name: String, grammar: Grammar = .code, configure: (inout SyntaxLanguage) -> Void = { _ in }) {
        self.name = name
        self.grammar = grammar
        configure(&self)
    }
}

// MARK: Choosing a language

extension SyntaxLanguage {
    /// The language for a file, by its name and extension, or for a script
    /// with no extension, by the interpreter its first line names.
    static func forPath(_ path: String, firstLine: String? = nil) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent
        let lowered = name.lowercased()
        if let language = byFileName[lowered] { return language }
        let ext = (lowered as NSString).pathExtension
        if !ext.isEmpty, let language = byExtension[ext] { return language }
        if let firstLine { return forShebang(firstLine) }
        return nil
    }

    /// The language a `#!` line names, such as `#!/usr/bin/env python3`.
    static func forShebang(_ line: String) -> SyntaxLanguage? {
        guard line.hasPrefix("#!") else { return nil }
        let words = line.dropFirst(2).split(whereSeparator: \.isWhitespace)
        guard var program = words.first.map({ String($0.split(separator: "/").last ?? $0) }) else { return nil }
        if program == "env", words.count > 1 {
            program = String(words[1...].first { !$0.hasPrefix("-") } ?? "")
        }
        program = program.trimmingCharacters(in: .decimalDigits.union(CharacterSet(charactersIn: ".")))
        switch program {
        case "sh", "bash", "zsh", "ksh", "dash", "fish": return .shell
        case "python", "pypy": return .python
        case "ruby": return .ruby
        case "node", "deno", "bun": return .javaScript
        case "swift": return .swift
        default: return nil
        }
    }

    private static let byExtension: [String: SyntaxLanguage] = {
        var table: [String: SyntaxLanguage] = [:]
        func add(_ language: SyntaxLanguage, _ extensions: String...) {
            for ext in extensions { table[ext] = language }
        }
        add(.swift, "swift")
        add(.c, "c", "h")
        add(.cpp, "cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "h++", "ipp", "inl")
        add(.objectiveC, "m", "mm")
        add(.rust, "rs")
        add(.go, "go")
        add(.python, "py", "pyw", "pyi")
        add(.javaScript, "js", "mjs", "cjs", "jsx")
        add(.typeScript, "ts", "mts", "cts", "tsx")
        add(.json, "json", "jsonc", "json5", "geojson", "webmanifest", "resolved")
        add(.yaml, "yml", "yaml")
        add(.toml, "toml")
        add(.markdown, "md", "markdown", "mdown", "mkd")
        add(.markup, "html", "htm", "xhtml", "xml", "svg", "plist", "xib", "storyboard", "entitlements", "xcscheme", "vue", "xsd", "xsl", "rss", "atom")
        add(.css, "css", "scss", "less")
        add(.shell, "sh", "bash", "zsh", "ksh", "command", "fish")
        add(.ruby, "rb", "rake", "gemspec", "podspec")
        add(.java, "java")
        add(.kotlin, "kt", "kts")
        add(.sql, "sql")
        return table
    }()

    private static let byFileName: [String: SyntaxLanguage] = [
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "fastfile": .ruby, "brewfile": .ruby,
        "dockerfile": .shell, ".bashrc": .shell, ".zshrc": .shell, ".profile": .shell, ".bash_profile": .shell,
        "cargo.lock": .toml, "pipfile": .toml, ".clang-format": .yaml, "package.resolved": .json
    ]
}

// MARK: The languages

private func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

private func words(_ text: String) -> Set<String> {
    Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
}

private func block(_ open: String, _ close: String, nests: Bool = false) -> SyntaxLanguage.BlockComment {
    .init(open: scalars(open), close: scalars(close), nests: nests)
}

private func string(_ open: String, _ close: String? = nil, escapes: Bool = true, multiline: Bool = false) -> SyntaxLanguage.StringRule {
    .init(open: scalars(open), close: scalars(close ?? open), escapes: escapes, multiline: multiline)
}

private func cFamilyComments(_ language: inout SyntaxLanguage) {
    language.lineComments = [scalars("//")]
    language.blockComments = [block("/*", "*/")]
}

private let cKeywords = "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Bool _Atomic _Generic _Noreturn _Static_assert alignas alignof"
private let cTypes = "void char short int long float double signed unsigned bool size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE"

extension SyntaxLanguage {
    static let swift = SyntaxLanguage("Swift") {
        $0.lineComments = [scalars("//")]
        $0.blockComments = [block("/*", "*/", nests: true)]
        $0.strings = [
            string("#\"\"\"", "\"\"\"#", escapes: false, multiline: true),
            string("\"\"\"", multiline: true),
            string("#\"", "\"#", escapes: false),
            string("\"")
        ]
        $0.keywords = words("""
            associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as is try await async throws actor any some nonisolated isolated consuming borrowing sending macro package lazy weak unowned mutating nonmutating override final required convenience dynamic indirect optional get set willSet didSet super self Self Type
            """)
        $0.literals = words("true false nil")
        $0.types = words("Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Bool String Character Void Never Any AnyObject")
        $0.capitalizedTypes = true
        $0.attributePrefixes = ["@", "#"]
    }

    static let c = SyntaxLanguage("C") {
        cFamilyComments(&$0)
        $0.strings = [string("\""), string("'")]
        $0.keywords = words(cKeywords)
        $0.types = words(cTypes)
        $0.literals = words("NULL true false")
        $0.preprocessor = true
    }

    static let cpp = SyntaxLanguage("C++") {
        cFamilyComments(&$0)
        $0.strings = [string("R\"(", ")\"", escapes: false, multiline: true), string("\""), string("'")]
        $0.keywords = words(cKeywords + " class namespace template typename public private protected virtual override final friend operator new delete this throw try catch using constexpr consteval constinit decltype explicit mutable noexcept static_assert static_cast dynamic_cast const_cast reinterpret_cast concept requires co_await co_return co_yield export module import")
        $0.types = words(cTypes + " wchar_t char8_t char16_t char32_t string vector map set")
        $0.literals = words("NULL nullptr true false")
        $0.capitalizedTypes = true
        $0.preprocessor = true
    }

    static let objectiveC = SyntaxLanguage("Objective-C") {
        cFamilyComments(&$0)
        $0.strings = [string("\""), string("'")]
        $0.keywords = words(cKeywords + " self super in out inout oneway bycopy byref nonnull nullable strong weak copy assign retain readonly readwrite atomic nonatomic class new delete this throw try catch namespace template public private protected virtual using")
        $0.types = words(cTypes + " id instancetype BOOL SEL IMP Class NSInteger NSUInteger CGFloat")
        $0.literals = words("nil Nil NULL YES NO true false nullptr")
        $0.capitalizedTypes = true
        $0.attributePrefixes = ["@"]
        $0.preprocessor = true
    }

    static let rust = SyntaxLanguage("Rust") {
        $0.lineComments = [scalars("//")]
        $0.blockComments = [block("/*", "*/", nests: true)]
        $0.strings = [
            string("r##\"", "\"##", escapes: false, multiline: true),
            string("r#\"", "\"#", escapes: false, multiline: true),
            string("r\"", "\"", escapes: false, multiline: true),
            string("b\"", "\"", multiline: true),
            string("\"", multiline: true)
        ]
        $0.characterLiterals = true
        $0.keywords = words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type union unsafe use where while yield macro_rules")
        $0.literals = words("true false None Some Ok Err")
        $0.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box")
        $0.capitalizedTypes = true
        $0.attributePrefixes = ["#"]
    }

    static let go = SyntaxLanguage("Go") {
        cFamilyComments(&$0)
        $0.strings = [string("`", escapes: false, multiline: true), string("\""), string("'")]
        $0.keywords = words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")
        $0.literals = words("true false nil iota")
        $0.types = words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable")
    }

    static let python = SyntaxLanguage("Python") {
        $0.lineComments = [scalars("#")]
        $0.strings = [
            string("\"\"\"", multiline: true), string("'''", multiline: true),
            string("\""), string("'")
        ]
        $0.keywords = words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls")
        $0.literals = words("True False None")
        $0.types = words("int float str bool bytes list dict set tuple object type complex frozenset")
        $0.capitalizedTypes = true
        $0.attributePrefixes = ["@"]
    }

    static let javaScript = SyntaxLanguage("JavaScript") {
        cFamilyComments(&$0)
        $0.strings = [string("`", multiline: true), string("\""), string("'")]
        $0.keywords = words("async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield")
        $0.literals = words("true false null undefined NaN Infinity")
        $0.capitalizedTypes = true
        $0.attributePrefixes = ["@"]
        $0.wordCharacters = ["$"]
    }

    static let typeScript = SyntaxLanguage("TypeScript") {
        $0 = .javaScript
        $0.name = "TypeScript"
        $0.keywords.formUnion(words("abstract as asserts declare enum implements infer interface is keyof module namespace override private protected public readonly satisfies type unique"))
        $0.types = words("any boolean never number object string symbol unknown void bigint")
    }

    static let json = SyntaxLanguage("JSON") {
        // Comments too, for the JSON files that allow them.
        cFamilyComments(&$0)
        $0.strings = [string("\"")]
        $0.literals = words("true false null")
        $0.keySeparators = [":"]
    }

    static let yaml = SyntaxLanguage("YAML") {
        $0.lineComments = [scalars("#")]
        $0.commentNeedsSpace = true
        $0.strings = [string("\""), string("'", escapes: false)]
        $0.literals = words("true false null yes no on off True False Null Yes No ~")
        $0.keySeparators = [":"]
        $0.keysStartLines = true
        $0.wordCharacters = ["-", "."]
        $0.attributePrefixes = ["&", "*", "!"]
    }

    static let toml = SyntaxLanguage("TOML") {
        $0.lineComments = [scalars("#")]
        $0.strings = [
            string("\"\"\"", multiline: true), string("'''", escapes: false, multiline: true),
            string("\""), string("'", escapes: false)
        ]
        $0.literals = words("true false inf nan")
        $0.keySeparators = ["="]
        $0.keysStartLines = true
        $0.wordCharacters = ["-", "."]
    }

    static let markdown = SyntaxLanguage("Markdown", grammar: .markdown)

    static let markup = SyntaxLanguage("HTML", grammar: .markup)

    static let css = SyntaxLanguage("CSS") {
        $0.lineComments = [scalars("//")] // SCSS and Less
        $0.blockComments = [block("/*", "*/")]
        $0.strings = [string("\""), string("'")]
        $0.keywords = words("!important inherit initial unset revert auto none")
        $0.keySeparators = [":"]
        $0.keysStartLines = true
        $0.wordCharacters = ["-"]
        $0.attributePrefixes = ["@", "#"]
        $0.variablePrefixes = ["$"]
    }

    static let shell = SyntaxLanguage("Shell") {
        $0.lineComments = [scalars("#")]
        $0.commentNeedsSpace = true
        $0.strings = [
            string("'", escapes: false, multiline: true),
            string("\"", multiline: true),
            string("`", multiline: true)
        ]
        $0.keywords = words("if then else elif fi case esac for select while until do done in function time coproc return exit break continue local export readonly declare typeset unset shift source alias set trap eval exec")
        $0.literals = words("true false")
        $0.variablePrefixes = ["$"]
        $0.wordCharacters = ["-"]
    }

    static let ruby = SyntaxLanguage("Ruby") {
        $0.lineComments = [scalars("#")]
        $0.strings = [string("\"", multiline: true), string("'", multiline: true), string("`")]
        $0.keywords = words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require require_relative attr_reader attr_writer attr_accessor private protected public lambda proc raise")
        $0.literals = words("true false nil")
        $0.capitalizedTypes = true
        $0.variablePrefixes = ["@", "$"]
        $0.wordCharacters = ["?", "!"]
    }

    static let java = SyntaxLanguage("Java") {
        cFamilyComments(&$0)
        $0.strings = [string("\"\"\"", multiline: true), string("\""), string("'")]
        $0.keywords = words("abstract assert break case catch class const continue default do else enum exports extends final finally for goto if implements import instanceof interface module native new package permits private protected public record requires return sealed static strictfp super switch synchronized this throw throws transient try var void volatile while yield")
        $0.literals = words("true false null")
        $0.types = words("boolean byte char double float int long short String Object")
        $0.capitalizedTypes = true
        $0.attributePrefixes = ["@"]
    }

    static let kotlin = SyntaxLanguage("Kotlin") {
        $0.lineComments = [scalars("//")]
        $0.blockComments = [block("/*", "*/", nests: true)]
        $0.strings = [string("\"\"\"", escapes: false, multiline: true), string("\""), string("'")]
        $0.keywords = words("abstract actual annotation as break by catch class companion const constructor continue crossinline data delegate do dynamic else enum expect external field final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package private protected public reified return sealed set super suspend tailrec this throw try typealias typeof val var vararg when where while value")
        $0.literals = words("true false null")
        $0.capitalizedTypes = true
        $0.attributePrefixes = ["@"]
    }

    static let sql = SyntaxLanguage("SQL") {
        $0.lineComments = [scalars("--")]
        $0.blockComments = [block("/*", "*/")]
        $0.strings = [string("'", escapes: false, multiline: true), string("\"")]
        $0.ignoresCase = true
        $0.keywords = words("select from where and or not insert into values update set delete create table view index drop alter add column primary key foreign references unique default check constraint join inner left right outer full cross on using group by order having limit offset union all distinct as case when then else end in is like between exists begin commit rollback transaction with recursive returning if replace trigger procedure function declare asc desc")
        $0.types = words("int integer bigint smallint tinyint real float double decimal numeric char varchar text blob boolean date time timestamp datetime serial uuid json jsonb")
        $0.literals = words("null true false")
    }
}
