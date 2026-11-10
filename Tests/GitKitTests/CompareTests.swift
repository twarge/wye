import Foundation
import GitKit
import Testing

@Suite struct CompareTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    private func makeHistory() throws {
        try fixture.commit("shared.txt", "base\n", message: "Base")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        try fixture.commit("topic.txt", "one\n", message: "Topic one")
        try fixture.commit("shared.txt", "topic\n", message: "Topic two")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.commit("main.txt", "main\n", message: "Main one")
    }

    @Test func commitsOnEachSideMatchRevListLeftRight() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let repository = try fixture.open()
        let main = try await repository.resolveRevision("main")
        let topic = try await repository.resolveRevision("topic")
        let comparison = try await repository.compare(main, topic)

        let sides = try fixture.git("rev-list", "--left-right", "main...topic").split(separator: "\n")
        let left = sides.filter { $0.hasPrefix("<") }.map { String($0.dropFirst()) }
        let right = sides.filter { $0.hasPrefix(">") }.map { String($0.dropFirst()) }
        #expect(comparison.onlyLeft.map(\.id.hex) == left)
        #expect(Set(comparison.onlyRight.map(\.id.hex)) == Set(right))
        #expect(comparison.leftCount == 1)
        #expect(comparison.rightCount == 2)

        let limited = try await repository.compare(main, topic, limit: 1)
        #expect(limited.onlyRight.count == 1)
        #expect(limited.rightCount == 2)
    }

    @Test func filesMatchGitDiff() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let repository = try fixture.open()
        let comparison = try await repository.compare(
            try await repository.resolveRevision("main"), try await repository.resolveRevision("topic")
        )
        let letters: [FileChange: String] = [.added: "A", .deleted: "D", .modified: "M", .renamed: "R"]
        let actual = comparison.files.map { "\(letters[$0.change] ?? "?")\t\($0.path)" }.joined(separator: "\n")
        #expect(actual == (try fixture.git("diff", "--name-status", "main", "topic")))
    }

    @Test func revisionsResolveLikeRevParse() async throws {
        defer { fixture.remove() }
        try makeHistory()
        try fixture.git("tag", "-a", "v1", "-m", "Annotated", "topic~1")
        let repository = try fixture.open()
        for revision in ["HEAD", "main~1", "topic", "v1", "refs/heads/topic"] {
            let expected = try fixture.git("rev-parse", "\(revision)^{commit}")
            #expect(try await repository.resolveRevision(revision).hex == expected, "\(revision)")
        }
        let head = try fixture.git("rev-parse", "HEAD")
        #expect(try await repository.resolveRevision(String(head.prefix(7))).hex == head)
        await #expect(throws: GitError.self) { try await repository.resolveRevision("no-such-branch") }
    }

    @Test func comparingACommitWithItselfIsEmpty() async throws {
        defer { fixture.remove() }
        try makeHistory()
        let repository = try fixture.open()
        let main = try await repository.resolveRevision("main")
        let comparison = try await repository.compare(main, main)
        #expect(comparison.onlyLeft.isEmpty && comparison.onlyRight.isEmpty && comparison.files.isEmpty)
    }
}
