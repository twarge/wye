import Foundation
import Testing
@testable import WyeUI

@Suite struct CommitMessageHelpTests {
    @Test func classifiesSubjectLength() {
        let fifty = String(repeating: "a", count: 50)
        #expect(SubjectLength.classify(fifty, soft: 50, hard: 72) == .fine)
        #expect(SubjectLength.classify(fifty + "b", soft: 50, hard: 72) == .long)
        #expect(SubjectLength.classify(String(repeating: "a", count: 72), soft: 50, hard: 72) == .long)
        #expect(SubjectLength.classify(String(repeating: "a", count: 73), soft: 50, hard: 72) == .tooLong)
        // Spaces around it do not count; characters are counted as people see them.
        #expect(SubjectLength.classify("  " + fifty + "  ", soft: 50, hard: 72) == .fine)
        #expect(SubjectLength.classify(String(repeating: "é", count: 50), soft: 50, hard: 72) == .fine)
        #expect(SubjectLength.classify(String(repeating: "👩‍👩‍👧", count: 51), soft: 50, hard: 72) == .long)
        // A limit of 0 is off.
        #expect(SubjectLength.classify(String(repeating: "a", count: 100), soft: 0, hard: 0) == .fine)
        #expect(SubjectLength.classify(String(repeating: "a", count: 100), soft: 50, hard: 0) == .long)
    }

    @Test func splitsMessagesAndTemplates() {
        #expect(CommitMessageText.split("Subject\n\nBody\nmore") == ("Subject", "Body\nmore"))
        #expect(CommitMessageText.split("Two\nlines\n\nBody") == ("Two lines", "Body"))
        #expect(CommitMessageText.split("# Explain\nFix: \n\n# Why?\nBecause\n", strippingComments: true)
            == ("Fix:", "Because"))
        #expect(CommitMessageText.split("# only comments", strippingComments: true) == ("", ""))
        #expect(CommitMessageText.split("#123 is fixed").subject == "#123 is fixed")
    }

    @Test func summarizesLongMessages() {
        #expect(CommitMessageText.summary("Short\n\nBody") == "Short")
        #expect(CommitMessageText.summary(String(repeating: "x", count: 80), limit: 10) == "xxxxxxxxx…")
    }

    @MainActor @Test func keepsTemplatesAndLimits() {
        let name = "CommitMessageHelpTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CommitPreferences(defaults: defaults)
        #expect(preferences.softLimit == 50 && preferences.hardLimit == 72)
        preferences.templates = [CommitTemplate(name: "Fix", text: "Fix: \n\n# Why")]
        preferences.softLimit = 0
        let reread = CommitPreferences(defaults: defaults)
        #expect(reread.templates.map(\.name) == ["Fix"])
        #expect(reread.softLimit == 0)
        #expect(reread.classify(String(repeating: "a", count: 60)) == .fine)
    }
}
