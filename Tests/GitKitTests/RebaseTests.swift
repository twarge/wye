import Foundation
import GitKit
import Testing

@Suite struct RebaseTests {
    /// `topic` has two commits on `Base`; `main` has moved on. With
    /// `conflict`, topic's first commit and main both change a.txt.
    private static func build(conflict: Bool) -> (Fixture) throws -> Void {
        { fixture in
            try fixture.commit("a.txt", "base\n", message: "Base")
            try fixture.git("checkout", "--quiet", "-b", "topic")
            try fixture.commit(conflict ? "a.txt" : "b.txt", "topic\n", message: "Topic one")
            try fixture.commit("c.txt", "two\n", message: "Topic two")
            try fixture.git("checkout", "--quiet", "main")
            try fixture.commit("a.txt", "main\n", message: "Main")
            try fixture.git("checkout", "--quiet", "topic")
        }
    }

    @Test func aCleanRebaseMatchesGit() async throws {
        let (ours, git) = try Fixture.twins(Self.build(conflict: false))
        defer { ours.remove(); git.remove() }
        let main = try ours.git("rev-parse", "main")

        #expect(try await ours.open().rebase(onto: "refs/heads/main") == .finished)
        try git.git("rebase", "--quiet", "main")

        // Same trees, authors and messages, in a line on top of main.
        #expect(try ours.contentLog() == git.contentLog())
        #expect(try ours.parentCounts() == [1, 1, 1, 0])
        #expect(try ours.git("rev-parse", "HEAD~2") == main)
        #expect(try ours.git("symbolic-ref", "HEAD") == "refs/heads/topic")
        #expect(try ours.git("status", "--porcelain") == "")
        #expect(try await ours.open().snapshot().state == .clean)
    }

    @Test func rebasingABranchThatIsBehindMovesItForward() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "base\n", message: "Base")
        try fixture.git("branch", "topic")
        let tip = try fixture.commit("a.txt", "main\n", message: "Main")
        try fixture.git("checkout", "--quiet", "topic")

        #expect(try await fixture.open().rebase(onto: "refs/heads/main") == .finished)
        #expect(try fixture.git("rev-parse", "topic") == tip)
        #expect(try fixture.git("symbolic-ref", "HEAD") == "refs/heads/topic")
    }

    @Test func aConflictStopsAndContinues() async throws {
        let (ours, git) = try Fixture.twins(Self.build(conflict: true))
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()
        let first = try #require(OID(hex: ours.git("rev-parse", "topic~1")))

        let outcome = try await repository.rebase(onto: "refs/heads/main")
        #expect(throws: (any Error).self) { try git.git("rebase", "--quiet", "main") }
        #expect(outcome == .stopped(at: first, conflicts: ["a.txt"]))
        #expect(try await repository.snapshot().state == .rebasing)
        // The same conflict, though libgit2 labels its sides differently.
        func sides(_ fixture: Fixture) throws -> [String] {
            try fixture.textOfFile("a.txt").split(separator: "\n").map {
                $0.hasPrefix("<<<<<<<") || $0.hasPrefix(">>>>>>>") ? String($0.prefix(7)) : String($0)
            }
        }
        #expect(try sides(ours) == sides(git))

        let operation = try #require(try await repository.ongoingOperation())
        #expect(operation.kind == .rebase)
        #expect(operation.commit == first)
        #expect(operation.summary == "Topic one")
        #expect(operation.step == 1)
        #expect(operation.total == 2)
        #expect(operation.queued == 1)
        #expect(operation.canSkip)
        await #expect(throws: BranchingError.unresolvedConflicts) { try await repository.continueOperation() }

        for fixture in [ours, git] {
            try fixture.write("resolved\n", to: "a.txt")
            try fixture.git("add", "a.txt")
        }
        #expect(try await repository.continueOperation() == .finished)
        try git.git("-c", "core.editor=true", "rebase", "--continue")

        #expect(try ours.contentLog() == git.contentLog())
        #expect(try ours.git("symbolic-ref", "HEAD") == "refs/heads/topic")
        #expect(try await repository.snapshot().state == .clean)
    }

    @Test func skipLeavesOutTheStoppedCommit() async throws {
        let (ours, git) = try Fixture.twins(Self.build(conflict: true))
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()

        _ = try await repository.rebase(onto: "refs/heads/main")
        #expect(throws: (any Error).self) { try git.git("rebase", "--quiet", "main") }
        #expect(try await repository.skipOperation() == .finished)
        try git.git("rebase", "--skip")

        #expect(try ours.contentLog() == git.contentLog())
        #expect(try ours.logFormat("%s") == ["Topic two", "Main", "Base"])
        #expect(try ours.git("status", "--porcelain") == "")
    }

    @Test func abortReturnsToTheOriginalBranch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build(conflict: true)(fixture)
        try fixture.write("untracked\n", to: "u.txt")
        let original = try fixture.git("rev-parse", "HEAD")
        let repository = try fixture.open()

        _ = try await repository.rebase(onto: "refs/heads/main")
        try await repository.abortOperation()
        #expect(try fixture.git("rev-parse", "HEAD") == original)
        #expect(try fixture.git("symbolic-ref", "HEAD") == "refs/heads/topic")
        #expect(try fixture.textOfFile("a.txt") == "topic\n")
        #expect(try fixture.git("status", "--porcelain") == "?? u.txt")
        #expect(try await repository.snapshot().state == .clean)
    }

    @Test func aRebaseRefusesLocalChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build(conflict: false)(fixture)
        try fixture.write("local\n", to: "c.txt")
        let original = try fixture.git("rev-parse", "HEAD")

        await #expect(throws: GitError.self) { try await fixture.open().rebase(onto: "refs/heads/main") }
        #expect(try fixture.git("rev-parse", "HEAD") == original)
        #expect(try await fixture.open().snapshot().state == .clean)
    }
}
