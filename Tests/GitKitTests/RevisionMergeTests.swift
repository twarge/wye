import Foundation
import GitKit
import Testing

/// Merging and rebasing onto a commit named by its hash rather than by a
/// reference, as the revision picker hands them over.
@Suite struct RevisionMergeTests {
    private static func divergent(_ fixture: Fixture) throws {
        try fixture.commit("a.txt", "base\n", message: "Base")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        try fixture.commit("b.txt", "topic\n", message: "Topic one")
        try fixture.commit("b.txt", "topic two\n", message: "Topic two")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.commit("c.txt", "main\n", message: "Main")
    }

    @Test func mergingAHashMatchesGit() async throws {
        let (ours, git) = try Fixture.twins(Self.divergent)
        defer { ours.remove(); git.remove() }
        // The commit before topic's tip, which no reference names.
        let hash = try ours.git("rev-parse", "topic~1")

        let outcome = try await ours.open().merge(hash, mode: .fastForwardWhenPossible)
        try git.git("merge", "--quiet", "--no-edit", hash)

        guard case .committed = outcome else {
            Issue.record("Expected a merge commit, got \(outcome)")
            return
        }
        #expect(try ours.logFormat("%T %P %s", "-1") == git.logFormat("%T %P %s", "-1"))
        #expect(try ours.logFormat("%s", "-1") == ["Merge commit '\(hash)'"])
    }

    @Test func fastForwardingToAHash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "base\n", message: "Base")
        let tip = try fixture.commit("a.txt", "next\n", message: "Next")
        try fixture.git("reset", "--quiet", "--hard", "HEAD~1")
        let outcome = try await fixture.open().merge(tip, mode: .fastForwardWhenPossible)
        #expect(outcome == .fastForwarded(to: OID(hex: tip)!))
        #expect(try fixture.git("rev-parse", "main") == tip)
    }

    @Test func rebasingOntoAHashMatchesGit() async throws {
        let (ours, git) = try Fixture.twins { fixture in
            try Self.divergent(fixture)
            try fixture.git("checkout", "--quiet", "topic")
        }
        defer { ours.remove(); git.remove() }
        let hash = try ours.git("rev-parse", "main")

        let outcome = try await ours.open().rebase(onto: hash)
        try git.git("rebase", "--quiet", hash)

        #expect(outcome == .finished)
        #expect(try ours.contentLog() == git.contentLog())
        #expect(try ours.git("rev-parse", "--abbrev-ref", "HEAD") == "topic")
    }
}
