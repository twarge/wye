import Foundation
import GitKit
import Testing
@testable import TwigUI

@Suite struct DiffTextStyleTests {
    @Test func leavesPlainTextWhole() {
        #expect(DiffTextStyle().runs("let x = 1") == [.init(text: "let x = 1", isInvisible: false)])
    }

    @Test func laysTabsOutToTheNextStop() {
        let style = DiffTextStyle(tabWidth: 4)
        #expect(style.runs("\tx") == [.init(text: "    x", isInvisible: false)])
        #expect(style.runs("ab\tc") == [.init(text: "ab  c", isInvisible: false)])
        #expect(style.runs("abcd\te") == [.init(text: "abcd    e", isInvisible: false)])
        #expect(DiffTextStyle(tabWidth: 8).runs("a\tb") == [.init(text: "a       b", isInvisible: false)])
    }

    @Test func drawsSpacesAndTabsWhenAsked() {
        let style = DiffTextStyle(tabWidth: 4, showsInvisibles: true)
        #expect(style.runs("a b") == [
            .init(text: "a", isInvisible: false), .init(text: "·", isInvisible: true), .init(text: "b", isInvisible: false)
        ])
        #expect(style.runs("\tx  ") == [
            .init(text: "→   ", isInvisible: true), .init(text: "x", isInvisible: false), .init(text: "··", isInvisible: true)
        ])
        #expect(style.runs("ab\t") == [.init(text: "ab", isInvisible: false), .init(text: "→ ", isInvisible: true)])
    }
}

@MainActor
@Suite struct DiffPreferenceTests {
    private func defaults() -> UserDefaults {
        let name = "DiffPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func startsFromGitsDefaultsAndKeepsChanges() {
        let defaults = defaults()
        let preferences = DiffPreferences(defaults: defaults)
        #expect(preferences.options == DiffOptions.standard)
        #expect(preferences.tabWidth == 4)
        #expect(preferences.collapseThreshold == 25)

        preferences.contextLines = 10
        preferences.whitespace = .amount
        preferences.collapseThreshold = nil
        let reread = DiffPreferences(defaults: defaults)
        #expect(reread.options == DiffOptions(contextLines: 10, whitespace: .amount))
        #expect(!reread.options.isExact)
        #expect(reread.collapseThreshold == nil)
    }

    @Test func foldsEveryFileOnlyPastTheThreshold() {
        let files = (0..<6).map { "file\($0).txt" }
        #expect(DiffPreferences.initiallyCollapsed(files, threshold: 5) == Set(files))
        #expect(DiffPreferences.initiallyCollapsed(files, threshold: 10).isEmpty)
        #expect(DiffPreferences.initiallyCollapsed(Array(files.prefix(5)), threshold: 5).isEmpty)
        #expect(DiffPreferences.initiallyCollapsed(files, threshold: nil).isEmpty)
    }
}
