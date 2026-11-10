import Foundation
import GitKit
import Testing

@Suite struct MergeDiffTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    @Test func aMergeIsComparedWithEachParent() async throws {
        defer { fixture.remove() }
        try fixture.commit("base.txt", "base\n", message: "Base")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        try fixture.commit("topic.txt", "topic\n", message: "Topic")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.commit("main.txt", "main\n", message: "Main")
        try fixture.git("merge", "--quiet", "--no-ff", "-m", "Merge topic", "topic")
        let merge = try #require(OID(hex: try fixture.git("rev-parse", "HEAD")))

        let repository = try fixture.open()
        let first = try await repository.changes(in: merge)
        #expect(first.map(\.path).joined(separator: "\n") == (try fixture.git("diff", "--name-only", "HEAD^1", "HEAD")))
        #expect(try await repository.changes(in: merge, parent: 0) == first)
        let second = try await repository.changes(in: merge, parent: 1)
        #expect(second.map(\.path).joined(separator: "\n") == (try fixture.git("diff", "--name-only", "HEAD^2", "HEAD")))
        #expect(first.map(\.path) == ["topic.txt"])
        #expect(second.map(\.path) == ["main.txt"])

        let fileDiff = try await repository.fileDiff(in: merge, path: "main.txt", parent: 1)
        #expect(fileDiff?.change == .added)
        #expect(try await repository.fileDiff(in: merge, path: "main.txt", parent: 0) == nil)
    }
}
