import Foundation
import GitKit
import Testing
@testable import TwigUI

/// Completions in the commit message's fields, worked out from the text
/// and the insertion point.
@Suite struct CommitCompletionTests {
    private let context = CompletionContext(
        paths: ["Sources/App/Parser.swift", "Sources/App/Printer.swift", "README.md"],
        sources: CommitCompletionSources(
            people: [GitIdentity(name: "Ada Lovelace", email: "ada@example.com"),
                     GitIdentity(name: "Grace Hopper", email: "grace@example.com")],
            issues: ["#123", "#12", "#45"],
            subjects: [
                .init(id: OID(hex: String(repeating: "a", count: 40))!, summary: "Parse dates"),
                .init(id: OID(hex: String(repeating: "b", count: 40))!, summary: "Print reports")
            ]
        )
    )

    private func match(_ text: String, isSubject: Bool = true) -> CommitCompletion.Match? {
        CommitCompletion.match(in: text, at: text.endIndex, isSubject: isSubject, context: context)
    }

    @Test func completesFileNamesAndPaths() {
        let names = match("Fix Par")?.suggestions.map(\.replacement)
        #expect(names == ["Parser.swift"])
        #expect(match("Fix Sources/App/Pr")?.suggestions.map(\.replacement) == ["Sources/App/Printer.swift"])
        #expect(match("Fix `Pri")?.suggestions.map(\.replacement) == ["Printer.swift"])
        // A single letter is too little to go on, and a finished name needs nothing.
        #expect(match("Fix P") == nil)
        #expect(match("Fix Parser.swift") == nil)
    }

    @Test func acceptingReplacesTheWordAndMovesTheInsertionPoint() throws {
        var text = "Fix Par in tests"
        let cursor = text.index(text.startIndex, offsetBy: 7)
        let found = try #require(CommitCompletion.match(in: text, at: cursor, isSubject: true, context: context))
        let end = CommitCompletion.accept(found.suggestions[0], in: &text, range: found.range)
        #expect(text == "Fix Parser.swift in tests")
        #expect(text[..<end] == "Fix Parser.swift")
    }

    @Test func completesIssuesAndMentions() {
        #expect(match("Closes #1")?.suggestions.map(\.replacement) == ["#123", "#12"])
        #expect(match("Closes #")?.suggestions.count == 3)
        #expect(match("Thanks @gra")?.suggestions.map(\.replacement) == ["Grace Hopper"])
    }

    @Test func completesCoAuthorTrailers() {
        #expect(match("Body\n\nCo-a", isSubject: false)?.suggestions.map(\.replacement) == ["Co-authored-by: "])
        // Not in the subject, where trailers do not go.
        #expect(match("Co-a", isSubject: true) == nil)
        let people = match("Body\n\nCo-authored-by: ada", isSubject: false)
        #expect(people?.suggestions.map(\.replacement) == ["Ada Lovelace <ada@example.com>"])
        #expect(match("Co-authored-by: ", isSubject: false)?.suggestions.count == 2)
    }

    @Test func completesFixupTargets() {
        #expect(match("fixup! par")?.suggestions.map(\.replacement) == ["Parse dates"])
        #expect(match("squash! ")?.suggestions.map(\.replacement) == ["Parse dates", "Print reports"])
        #expect(match("fixup! Parse dates") == nil)
        var text = "fixup! rep"
        let found = match(text)!
        _ = CommitCompletion.accept(found.suggestions[0], in: &text, range: found.range)
        #expect(text == "fixup! Print reports")
    }
}

/// Author profiles: the one identity there was before becomes the first,
/// and a commit's profile and signing are worked out from the settings.
@MainActor
@Suite struct AuthorProfileTests {
    private func defaults() -> UserDefaults {
        let name = "AuthorProfileTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func migratesTheGlobalIdentity() throws {
        let store = defaults()
        let profiles = AuthorProfiles(defaults: store, globalIdentity: { GitIdentity(name: "Old", email: "old@example.com") },
                                      writeGlobalIdentity: { _ in })
        #expect(profiles.profiles.map(\.identity) == [GitIdentity(name: "Old", email: "old@example.com")])
        #expect(profiles.defaultProfile?.name == "Old")
        // Read back as saved, not migrated again.
        let again = AuthorProfiles(defaults: store, globalIdentity: { nil }, writeGlobalIdentity: { _ in })
        #expect(again.profiles == profiles.profiles)
        #expect(again.defaultID == profiles.defaultID)
    }

    @Test func theDefaultIsWrittenToTheGlobalConfiguration() throws {
        var written: [GitIdentity] = []
        let profiles = AuthorProfiles(defaults: defaults(), globalIdentity: { nil }, writeGlobalIdentity: { written.append($0) })
        let work = AuthorProfile(name: "Work", email: "me@work.example")
        let home = AuthorProfile(name: "Home", email: "me@home.example")
        try profiles.save(work)
        try profiles.save(home)
        #expect(written == [work.identity])
        try profiles.makeDefault(home)
        #expect(written == [work.identity, home.identity])
        try profiles.remove(home)
        #expect(profiles.defaultProfile == work)
        #expect(written.last == work.identity)
    }

    @Test func picksTheProfileAndSigningForACommit() throws {
        let profiles = AuthorProfiles(defaults: defaults(), globalIdentity: { nil }, writeGlobalIdentity: { _ in })
        let work = AuthorProfile(name: "Work", email: "me@work.example", signingKeyID: "work-key", signsCommits: true)
        let home = AuthorProfile(name: "Home", email: "me@home.example")
        try profiles.save(work)
        try profiles.save(home)
        profiles.signingKeyID = "app-key"

        #expect(profiles.chosenProfile(forCommit: nil, repository: nil) == nil)
        #expect(profiles.chosenProfile(forCommit: nil, repository: home.id) == home)
        #expect(profiles.chosenProfile(forCommit: work.id, repository: home.id) == work)

        #expect(profiles.signingPlan(for: work, repositorySigns: nil) == SigningPlan(signs: true, keyID: "work-key"))
        #expect(profiles.signingPlan(for: home, repositorySigns: nil) == SigningPlan(signs: false, keyID: nil))
        profiles.signsCommits = true
        #expect(profiles.signingPlan(for: home, repositorySigns: nil) == SigningPlan(signs: true, keyID: "app-key"))
        #expect(profiles.signingPlan(for: work, repositorySigns: false) == SigningPlan(signs: false, keyID: nil))
        // No profile picked: the default's settings.
        #expect(profiles.signingPlan(for: nil, repositorySigns: nil) == SigningPlan(signs: true, keyID: "work-key"))
    }
}
