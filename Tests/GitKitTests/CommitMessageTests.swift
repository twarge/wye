import Foundation
import GitKit
import Testing

@Suite struct CommitMessageTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    @Test func listsRecentMessagesByTheCurrentAuthor() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "1", message: "Add a")
        try fixture.commit("a.txt", "2", message: "Fix a\n\nWith a body.")
        try fixture.write("3", to: "a.txt")
        try fixture.git("commit", "--quiet", "-am", "By someone else", "--author=Other <other@example.com>")
        try fixture.commit("a.txt", "4", message: "Add a")
        try fixture.commit("a.txt", "5", message: "Last")

        let messages = try await fixture.open().recentCommitMessages()
        // git's own list of this author's messages, newest first, each once.
        var expected: [String] = []
        for message in try fixture.git("log", "--author=author@example.com", "--format=%B%x00")
            .components(separatedBy: "\0") {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !expected.contains(trimmed) { expected.append(trimmed) }
        }
        #expect(messages == expected)
        #expect(messages == ["Last", "Add a", "Fix a\n\nWith a body."])
        #expect(try await fixture.open().recentCommitMessages(limit: 2) == ["Last", "Add a"])
    }

    @Test func hasNoMessagesBeforeTheFirstCommit() async throws {
        defer { fixture.remove() }
        #expect(try await fixture.open().recentCommitMessages().isEmpty)
    }

    @Test func readsATemplateInsideTheRepository() async throws {
        defer { fixture.remove() }
        try fixture.write("Subject\n\n# Explain why\n", to: ".github/template.txt")
        let repository = try fixture.open()
        #expect(try await repository.commitTemplate() == nil)

        try fixture.git("config", "commit.template", ".github/template.txt")
        #expect(try await repository.commitTemplate() == "Subject\n\n# Explain why\n")

        try fixture.git("config", "commit.template", fixture.url.appending(path: ".github/template.txt").path)
        #expect(try await repository.commitTemplate() == "Subject\n\n# Explain why\n")

        // Outside the working tree, or in the home folder: not read.
        try fixture.git("config", "commit.template", "../outside.txt")
        #expect(try await repository.commitTemplate() == nil)
        try fixture.git("config", "commit.template", "~/.gitmessage")
        #expect(try await repository.commitTemplate() == nil)
    }
}
