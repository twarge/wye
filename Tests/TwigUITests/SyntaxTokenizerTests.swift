import Foundation
import GitKit
import Testing
@testable import TwigUI

/// Writes each line with its tokens bracketed, `[keyword let] x = [number 1]`,
/// so a golden test reads like the source it colours.
private func golden(_ language: SyntaxLanguage, _ text: String) -> [String] {
    let lines = text.components(separatedBy: "\n")
    let tokens = SyntaxTokenizer(language).tokenize(lines)
    return zip(lines, tokens).map { line, tokens in
        let scalars = Array(line.unicodeScalars)
        var output = ""
        var position = 0
        func slice(_ start: Int, _ end: Int) -> String {
            String(String.UnicodeScalarView(scalars[start..<end]))
        }
        for token in tokens {
            output += slice(position, token.start)
            output += "[\(token.role) \(slice(token.start, token.end))]"
            position = token.end
        }
        output += slice(position, scalars.count)
        return output
    }
}

@Suite struct SyntaxTokenizerTests {
    @Test func swift() {
        #expect(golden(.swift, """
            @MainActor final class Box: View { // a box
                let count = 0x1F + 2.5e-3
                var name: String? = nil
                #if DEBUG
            }
            """) == [
            "[attribute @MainActor] [keyword final] [keyword class] [type Box]: [type View] { [comment // a box]",
            "    [keyword let] count = [number 0x1F] + [number 2.5e-3]",
            "    [keyword var] name: [type String]? = [literal nil]",
            "    [attribute #if] DEBUG",
            "}"
        ])
    }

    @Test func swiftRangesAreNotDecimals() {
        #expect(golden(.swift, "for i in 0..<10 {}") == ["[keyword for] i [keyword in] [number 0]..<[number 10] {}"])
    }

    @Test func swiftStringsAndEscapes() {
        #expect(golden(.swift, ##"let s = "a \"quoted\" word", t = #"raw \"#"##) == [
            ##"[keyword let] s = [string "a \"quoted\" word"], t = [string #"raw \"#]"##
        ])
    }

    @Test func swiftMultilineStringCarriesAcrossLines() {
        #expect(golden(.swift, """
            let text = \"""
                let inside = 1 // not code
                \"""
            let after = 2
            """) == [
            "[keyword let] text = [string \"\"\"]",
            "[string     let inside = 1 // not code]",
            "[string     \"\"\"]",
            "[keyword let] after = [number 2]"
        ])
    }

    @Test func swiftBlockCommentsNest() {
        #expect(golden(.swift, """
            /* outer /* inner */
            still comment */ let x = 1
            """) == [
            "[comment /* outer /* inner */]",
            "[comment still comment */] [keyword let] x = [number 1]"
        ])
    }

    @Test func cPreprocessorAndComments() {
        #expect(golden(.c, """
            #include <stdio.h>
            /* a
               b */ int main(void) { return 'x'; }
            """) == [
            "[attribute #include] <stdio.h>",
            "[comment /* a]",
            "[comment    b */] [type int] main([type void]) { [keyword return] [string 'x']; }"
        ])
    }

    @Test func cBlockCommentsDoNotNest() {
        #expect(golden(.c, "/* a /* b */ int x;") == ["[comment /* a /* b */] [type int] x;"])
    }

    @Test func cppAndObjectiveC() {
        #expect(golden(.cpp, "template <typename T> class Vec : public Base {};") == [
            "[keyword template] <[keyword typename] T> [keyword class] [type Vec] : [keyword public] [type Base] {};"
        ])
        #expect(golden(.objectiveC, "@interface Foo : NSObject @property BOOL ok; @end") == [
            "[attribute @interface] [type Foo] : [type NSObject] [attribute @property] [type BOOL] ok; [attribute @end]"
        ])
    }

    @Test func rustLifetimesCharactersAndRawStrings() {
        #expect(golden(.rust, ##"#[derive(Debug)] fn f<'a>(c: char) -> &'a str { let x = 'z'; r#"raw "q""# }"##) == [
            ##"[attribute #[derive(Debug)]] [keyword fn] f<[attribute 'a]>(c: [type char]) -> &[attribute 'a] [type str] { [keyword let] x = [string 'z']; [string r#"raw "q""#] }"##
        ])
    }

    @Test func rustStringsRunOn() {
        #expect(golden(.rust, "let s = \"one\ntwo\";") == ["[keyword let] s = [string \"one]", "[string two\"];"])
    }

    @Test func goRawStrings() {
        #expect(golden(.go, "var s = `a\nb` // done\nfunc main() {}") == [
            "[keyword var] s = [string `a]",
            "[string b`] [comment // done]",
            "[keyword func] main() {}"
        ])
    }

    @Test func python() {
        #expect(golden(.python, """
            @decorator
            def f(x: int) -> None:  # note
                \"""Doc
                string\"""
                return True
            """) == [
            "[attribute @decorator]",
            "[keyword def] f(x: [type int]) -> [literal None]:  [comment # note]",
            "    [string \"\"\"Doc]",
            "[string     string\"\"\"]",
            "    [keyword return] [literal True]"
        ])
    }

    @Test func javaScriptTemplateLiteralRunsOn() {
        #expect(golden(.javaScript, "const s = `a ${b}\nc`; let $x = null") == [
            "[keyword const] s = [string `a ${b}]",
            "[string c`]; [keyword let] $x = [literal null]"
        ])
    }

    @Test func typeScript() {
        #expect(golden(.typeScript, "interface Item { n: number } // x") == [
            "[keyword interface] [type Item] { n: [type number] } [comment // x]"
        ])
    }

    @Test func jsonKeysAndValues() {
        #expect(golden(.json, #"{"name": "twig", "count": 3, "ok": true, "none": null}"#) == [
            #"{[property "name"]: [string "twig"], [property "count"]: [number 3], [property "ok"]: [literal true], [property "none"]: [literal null]}"#
        ])
    }

    @Test func yaml() {
        #expect(golden(.yaml, """
            name: twig # comment
            url: http://example.com/#anchor
            - key: 'value'
              flag: yes
            """) == [
            "[property name]: twig [comment # comment]",
            "[property url]: http://example.com/#anchor",
            "- [property key]: [string 'value']",
            "  [property flag]: [literal yes]"
        ])
    }

    @Test func toml() {
        #expect(golden(.toml, """
            [package]
            name = "twig" # c
            text = '''
            multi
            '''
            """) == [
            "[package]",
            "[property name] = [string \"twig\"] [comment # c]",
            "[property text] = [string ''']",
            "[string multi]",
            "[string ''']"
        ])
    }

    @Test func markdown() {
        #expect(golden(.markdown, """
            # Title
            Some **bold**, *it*, snake_case_name and `code` with [a link](https://x).
            - item
            ```swift
            let x = 1
            ```
            after
            """) == [
            "[heading # Title]",
            "Some [emphasis **bold**], [emphasis *it*], snake_case_name and [string `code`] with [link [a link](https://x)].",
            "[keyword -] item",
            "[string ```swift]",
            "[string let x = 1]",
            "[string ```]",
            "after"
        ])
    }

    @Test func markupTagsAttributesAndComments() {
        #expect(golden(.markup, """
            <a href="x.html" class='c'>Tom &amp; Jerry</a>
            <!-- one
            two --> <br/>
            <img
              src="y.png">
            """) == [
            "[tag <a] [property href]=[string \"x.html\"] [property class]=[string 'c'][tag >]Tom [literal &amp;] Jerry[tag </a>]",
            "[comment <!-- one]",
            "[comment two -->] [tag <br/>]",
            "[tag <img]",
            "  [property src]=[string \"y.png\"][tag >]"
        ])
    }

    @Test func css() {
        #expect(golden(.css, """
            @media screen {
              a:hover { color: #fff; margin: 10px !important; } /* c */
              font-size: 1.5em;
            }
            """) == [
            "[attribute @media] screen {",
            "  a:hover { color: [attribute #fff]; margin: [number 10px] [keyword !important]; } [comment /* c */]",
            "  [property font-size]: [number 1.5em];",
            "}"
        ])
    }

    @Test func shell() {
        #expect(golden(.shell, """
            if [ -n "$HOME" ]; then echo ${USER} $1 # c
            fi
            echo 'one
            two' a#b
            """) == [
            "[keyword if] [ -n [string \"$HOME\"] ]; [keyword then] echo [variable ${USER}] [variable $1] [comment # c]",
            "[keyword fi]",
            "echo [string 'one]",
            "[string two'] a#b"
        ])
    }

    @Test func ruby() {
        #expect(golden(.ruby, "class Foo < Bar\n  def ok?; @count = nil; end # c\nend") == [
            "[keyword class] [type Foo] < [type Bar]",
            "  [keyword def] ok?; [variable @count] = [literal nil]; [keyword end] [comment # c]",
            "[keyword end]"
        ])
    }

    @Test func javaAndKotlin() {
        #expect(golden(.java, "@Override public String name() { return \"\"; }") == [
            "[attribute @Override] [keyword public] [type String] name() { [keyword return] [string \"\"]; }"
        ])
        #expect(golden(.kotlin, "val x: Int = 1 /* a /* b */ c */ fun f() = null") == [
            "[keyword val] x: [type Int] = [number 1] [comment /* a /* b */ c */] [keyword fun] f() = [literal null]"
        ])
    }

    @Test func sqlIgnoresCase() {
        #expect(golden(.sql, "SELECT name FROM users WHERE id = 'it''s' -- c\nInsert into t values (1);") == [
            "[keyword SELECT] name [keyword FROM] users [keyword WHERE] id = [string 'it''s'] [comment -- c]",
            "[keyword Insert] [keyword into] t [keyword values] ([number 1]);"
        ])
    }

    @Test func veryLongLinesStayPlainAndKeepState() {
        let long = String(repeating: "x", count: SyntaxTokenizer.maximumLineLength + 1)
        let tokenizer = SyntaxTokenizer(.swift)
        let result = tokenizer.tokenize(long, from: .comment(0, depth: 1))
        #expect(result.tokens.isEmpty)
        #expect(result.state == .comment(0, depth: 1))
    }

    @Test func choosesLanguageByNameExtensionAndShebang() {
        #expect(SyntaxLanguage.forPath("Sources/App/main.swift")?.name == "Swift")
        #expect(SyntaxLanguage.forPath("include/x.hpp")?.name == "C++")
        #expect(SyntaxLanguage.forPath("web/app.TSX")?.name == "TypeScript")
        #expect(SyntaxLanguage.forPath("Gemfile")?.name == "Ruby")
        #expect(SyntaxLanguage.forPath("Info.plist")?.name == "HTML")
        #expect(SyntaxLanguage.forPath("bin/tool", firstLine: "#!/usr/bin/env python3")?.name == "Python")
        #expect(SyntaxLanguage.forPath("bin/run", firstLine: "#!/bin/bash -e")?.name == "Shell")
        #expect(SyntaxLanguage.forPath("bin/run", firstLine: "#!/usr/bin/env -S node --flag")?.name == "JavaScript")
        #expect(SyntaxLanguage.forPath("LICENSE") == nil)
    }
}

@Suite struct DiffDecorationTests {
    private func line(_ id: Int, _ kind: FileDiff.Line.Kind, _ text: String, old: Int?, new: Int?) -> FileDiff.Line {
        FileDiff.Line(id: id, kind: kind, oldNumber: old, newNumber: new, text: text)
    }

    private func file(_ path: String, _ lines: [FileDiff.Line]) -> FileDiff {
        FileDiff(
            change: .modified, oldPath: path, path: path, isBinary: false, additions: 0, deletions: 0,
            hunks: [FileDiff.Hunk(id: 0, header: "@@", lines: lines)], isTruncated: false
        )
    }

    /// A comment opened on the new side colours later added and unchanged
    /// lines, but not removed ones: each side is read as its own text.
    @Test func eachSideCarriesItsOwnState() {
        let diff = file("a.swift", [
            line(0, .context, "let a = 1", old: 1, new: 1),
            line(1, .addition, "/* start", old: nil, new: 2),
            line(2, .context, "let b = 2", old: 2, new: 3),
            line(3, .deletion, "let c = 3", old: 3, new: nil),
            line(4, .addition, "end */ let d = 4", old: nil, new: 4)
        ])
        let decorations = DiffDecorations.make(for: diff)
        #expect(decorations.tokens[2] == [SyntaxToken(start: 0, length: 9, role: .comment)])
        #expect(decorations.tokens[3]?.first?.role == .keyword)
        #expect(decorations.tokens[4]?.first == SyntaxToken(start: 0, length: 6, role: .comment))
    }

    @Test func marksTheChangedPartOfReplacedLines() {
        let diff = file("a.txt", [
            line(0, .deletion, "let count = 10", old: 1, new: nil),
            line(1, .deletion, "removed alone", old: 2, new: nil),
            line(2, .addition, "let count = 25", old: nil, new: 1)
        ])
        let marks = DiffDecorations.changeMarks(in: diff)
        #expect(marks[0] == [LineMark(start: 12, end: 14, kind: .change)])
        #expect(marks[2] == [LineMark(start: 12, end: 14, kind: .change)])
        #expect(marks[1] == nil)
    }

    @Test func leavesLinesWithNothingInCommonUnmarked() {
        #expect(DiffDecorations.differingRanges("abc", "xyz") == nil)
        #expect(DiffDecorations.differingRanges("    abc", "    xyz") == nil)
        let ranges = DiffDecorations.differingRanges("foo(a)", "foo(a, b)")
        #expect(ranges?.0 == 5..<5)
        #expect(ranges?.1 == 5..<8)
    }
}

@Suite struct CodeLineRendererTests {
    @Test func plainTextComesBackWhole() {
        #expect(String(CodeLineRenderer().render("let x = 1").characters) == "let x = 1")
    }

    @Test func tabsAndInvisiblesAreLaidOut() {
        let renderer = CodeLineRenderer(tabWidth: 4, showsInvisibles: true)
        #expect(String(renderer.render("a\tb c").characters) == "a→  b·c")
    }

    @Test func colorsTokensAndMarksMatches() {
        let renderer = CodeLineRenderer(theme: .classic)
        let text = renderer.render("let x", tokens: [SyntaxToken(start: 0, length: 3, role: .keyword)],
                                   marks: [LineMark(start: 4, end: 5, kind: .currentMatch)])
        let runs = text.runs.map {
            (String(text[$0.range].characters), $0.swiftUI.foregroundColor != nil, $0.swiftUI.backgroundColor != nil)
        }
        #expect(runs.map(\.0) == ["let", " ", "x"])
        #expect(runs.map(\.1) == [true, false, false])
        #expect(runs.map(\.2) == [false, false, true])
    }
}
