import Foundation
import GitKit
import Testing

/// `main` and `topic` both changed since `Base`: `topic` adds b.txt and
/// `main` adds c.txt, so they merge cleanly.
private func divergent(_ fixture: Fixture) throws {
    try fixture.commit("a.txt", "base\n", message: "Base")
    try fixture.git("checkout", "--quiet", "-b", "topic")
    try fixture.commit("b.txt", "topic\n", message: "Topic one")
    try fixture.commit("b.txt", "topic two\n", message: "Topic two")
    try fixture.git("checkout", "--quiet", "main")
    try fixture.commit("c.txt", "main\n", message: "Main")
}

/// `main` and `topic` both changed a.txt since `Base`.
private func conflicting(_ fixture: Fixture) throws {
    try fixture.commit("a.txt", "base\n", message: "Base")
    try fixture.commit("other.txt", "other\n", message: "Other")
    try fixture.git("checkout", "--quiet", "-b", "topic")
    try fixture.commit("a.txt", "topic\n", message: "Topic")
    try fixture.git("checkout", "--quiet", "main")
    try fixture.commit("a.txt", "main\n", message: "Main")
}

@Suite struct MergeTests {
    @Test func fastForwardsWhenPossible() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "base\n", message: "Base")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        let tip = try fixture.commit("b.txt", "topic\n", message: "Topic")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.write("unrelated\n", to: "a.txt")

        let repository = try fixture.open()
        let outcome = try await repository.merge("refs/heads/topic", mode: .fastForwardWhenPossible)
        #expect(outcome == .fastForwarded(to: OID(hex: tip)!))
        #expect(try fixture.logFormat("%H %P") == fixture.logFormat("%H %P", "topic"))
        #expect(try fixture.textOfFile("b.txt") == "topic\n")
        // A local change the merge does not touch is kept.
        #expect(try fixture.git("status", "--porcelain") == "M a.txt")

        #expect(try await repository.merge("refs/heads/topic", mode: .fastForwardWhenPossible) == .upToDate)
    }

    @Test func alwaysCommitMakesAMergeCommitWhereAFastForwardWouldDo() async throws {
        let (ours, git) = try Fixture.twins { fixture in
            try fixture.commit("a.txt", "base\n", message: "Base")
            try fixture.git("checkout", "--quiet", "-b", "topic")
            try fixture.commit("b.txt", "topic\n", message: "Topic")
            try fixture.git("checkout", "--quiet", "main")
        }
        defer { ours.remove(); git.remove() }

        let outcome = try await ours.open().merge("refs/heads/topic", mode: .alwaysCommit)
        try git.git("merge", "--quiet", "--no-ff", "--no-edit", "topic")

        guard case .committed(let id) = outcome else {
            Issue.record("Expected a merge commit, got \(outcome)")
            return
        }
        #expect(try ours.git("rev-parse", "HEAD") == id.hex)
        #expect(try ours.logFormat("%T %P %s", "-1") == git.logFormat("%T %P %s", "-1"))
        #expect(try ours.git("log", "-1", "--format=%B") == "Merge branch 'topic'")
        #expect(try ours.git("status", "--porcelain") == "")
    }

    @Test func aCleanMergeMatchesGit() async throws {
        let (ours, git) = try Fixture.twins(divergent)
        defer { ours.remove(); git.remove() }

        let outcome = try await ours.open().merge("refs/heads/topic", mode: .fastForwardWhenPossible)
        try git.git("merge", "--quiet", "--no-edit", "topic")

        guard case .committed = outcome else {
            Issue.record("Expected a merge commit, got \(outcome)")
            return
        }
        // Same tree, same parents, same message.
        #expect(try ours.logFormat("%T %P %s", "-1") == git.logFormat("%T %P %s", "-1"))
        #expect(try ours.parentCounts() == git.parentCounts())
        #expect(try ours.git("log", "-1", "--format=%an <%ae>") == "Test Author <author@example.com>")
        #expect(try await ours.open().snapshot().state == .clean)
    }

    @Test func mergingIntoAnotherBranchNamesIt() async throws {
        let (ours, git) = try Fixture.twins { fixture in
            try divergent(fixture)
            try fixture.git("checkout", "--quiet", "-b", "release")
        }
        defer { ours.remove(); git.remove() }
        try await ours.open().merge("refs/heads/topic", mode: .alwaysCommit)
        try git.git("merge", "--quiet", "--no-edit", "topic")
        #expect(try ours.logFormat("%s", "-1") == ["Merge branch 'topic' into release"])
        #expect(try ours.logFormat("%T %P %s", "-1") == git.logFormat("%T %P %s", "-1"))
    }

    @Test func aSquashMakesOneOrdinaryCommit() async throws {
        let (ours, git) = try Fixture.twins(divergent)
        defer { ours.remove(); git.remove() }

        let outcome = try await ours.open().merge("refs/heads/topic", mode: .squash, message: "Squashed topic")
        try git.git("merge", "--quiet", "--squash", "topic")
        try git.git("commit", "--quiet", "-m", "Squashed topic")

        guard case .committed = outcome else {
            Issue.record("Expected a commit, got \(outcome)")
            return
        }
        #expect(try ours.logFormat("%T %P %s", "-1") == git.logFormat("%T %P %s", "-1"))
        #expect(try ours.parentCounts() == [1, 1, 0])
        #expect(!ours.fileExists(".git/MERGE_HEAD"))
        #expect(try await ours.open().snapshot().state == .clean)
    }

    @Test func aConflictStopsAndIsConcluded() async throws {
        let (ours, git) = try Fixture.twins(conflicting)
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()

        let outcome = try await repository.merge("refs/heads/topic", mode: .fastForwardWhenPossible)
        #expect(throws: (any Error).self) { try git.git("merge", "--quiet", "--no-edit", "topic") }
        #expect(outcome == .conflicts(["a.txt"]))
        #expect(try await repository.snapshot().state == .merging)
        #expect(try ours.git("status", "--porcelain") == git.git("status", "--porcelain"))
        #expect(try ours.textOfFile("a.txt") == git.textOfFile("a.txt"))

        let operation = try #require(try await repository.ongoingOperation())
        #expect(operation.kind == .merge)
        #expect(operation.summary == "Merge branch 'topic'")
        #expect(operation.conflictedPaths == ["a.txt"])
        #expect(!operation.canSkip)
        await #expect(throws: BranchingError.unresolvedConflicts) { try await repository.continueOperation() }
        await #expect(throws: BranchingError.operationInProgress(.merging)) {
            try await repository.merge("refs/heads/topic", mode: .alwaysCommit)
        }

        for fixture in [ours, git] {
            try fixture.write("resolved\n", to: "a.txt")
            try fixture.git("add", "a.txt")
        }
        #expect(try await repository.continueOperation() == .finished)
        try git.git("commit", "--quiet", "--no-edit")

        #expect(try ours.logFormat("%T %P %s", "-1") == git.logFormat("%T %P %s", "-1"))
        #expect(try await repository.snapshot().state == .clean)
        #expect(try await repository.ongoingOperation() == nil)
    }

    @Test func abortingAMergeKeepsUnrelatedChanges() async throws {
        let (ours, git) = try Fixture.twins { fixture in
            try conflicting(fixture)
            try fixture.write("unrelated\n", to: "other.txt")
        }
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()

        #expect(try await repository.merge("refs/heads/topic", mode: .alwaysCommit) == .conflicts(["a.txt"]))
        #expect(throws: (any Error).self) { try git.git("merge", "--quiet", "--no-edit", "topic") }
        try await repository.abortOperation()
        try git.git("merge", "--abort")

        #expect(try ours.git("status", "--porcelain") == git.git("status", "--porcelain"))
        #expect(try ours.git("status", "--porcelain") == "M other.txt")
        #expect(try ours.textOfFile("a.txt") == "main\n")
        #expect(try ours.git("rev-parse", "HEAD") == git.git("rev-parse", "HEAD"))
        #expect(try await repository.snapshot().state == .clean)
    }

    /// One side changed the file and the other deleted it.
    private func modifyDelete(_ fixture: Fixture, deletedOn deleter: String) throws {
        try fixture.commit("a.txt", "base\n", message: "Base")
        try fixture.commit("other.txt", "other\n", message: "Other")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        if deleter == "topic" {
            try fixture.git("rm", "--quiet", "a.txt")
            try fixture.git("commit", "--quiet", "-m", "Topic deletes")
        } else {
            try fixture.commit("a.txt", "topic\n", message: "Topic")
        }
        try fixture.git("checkout", "--quiet", "main")
        if deleter == "main" {
            try fixture.git("rm", "--quiet", "a.txt")
            try fixture.git("commit", "--quiet", "-m", "Main deletes")
        } else {
            try fixture.commit("a.txt", "main\n", message: "Main")
        }
    }

    @Test(arguments: ["topic", "main"])
    func abortingAMergeStoppedOnAModifyDeleteConflict(deleter: String) async throws {
        let (ours, git) = try Fixture.twins { try modifyDelete($0, deletedOn: deleter) }
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()

        #expect(try await repository.merge("refs/heads/topic", mode: .alwaysCommit) == .conflicts(["a.txt"]))
        #expect(throws: (any Error).self) { try git.git("merge", "--quiet", "--no-edit", "topic") }
        try await repository.abortOperation()
        try git.git("merge", "--abort")

        #expect(try ours.git("status", "--porcelain") == "")
        #expect(try ours.git("status", "--porcelain") == git.git("status", "--porcelain"))
        #expect(ours.fileExists("a.txt") == git.fileExists("a.txt"))
        #expect(try await repository.snapshot().state == .clean)
    }

    @Test(arguments: ["topic", "main"])
    func skippingACherryPickStoppedOnAModifyDeleteConflict(deleter: String) async throws {
        let (ours, git) = try Fixture.twins { try modifyDelete($0, deletedOn: deleter) }
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()
        let pick = try ours.git("rev-parse", "topic")

        #expect(try await repository.cherryPick([OID(hex: pick)!]) == .stopped(at: OID(hex: pick)!, conflicts: ["a.txt"]))
        #expect(throws: (any Error).self) { try git.git("cherry-pick", "topic") }
        try await repository.skipOperation()
        try git.git("cherry-pick", "--skip")

        #expect(try ours.git("status", "--porcelain") == "")
        #expect(try ours.git("status", "--porcelain") == git.git("status", "--porcelain"))
        #expect(ours.fileExists("a.txt") == git.fileExists("a.txt"))
        #expect(try ours.git("rev-parse", "HEAD") == git.git("rev-parse", "HEAD"))
        #expect(try await repository.snapshot().state == .clean)
    }

    @Test func abortingAMergeRemovesFilesItAdded() async throws {
        let (ours, git) = try Fixture.twins { fixture in
            try conflicting(fixture)
            try fixture.git("checkout", "--quiet", "topic")
            try fixture.commit("new.txt", "new\n", message: "Topic adds a file")
            try fixture.git("checkout", "--quiet", "main")
        }
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()
        #expect(try await repository.merge("refs/heads/topic", mode: .alwaysCommit) == .conflicts(["a.txt"]))
        #expect(ours.fileExists("new.txt"))
        try await repository.abortOperation()
        #expect(!ours.fileExists("new.txt"))
        #expect(try ours.git("status", "--porcelain") == "")
    }

    @Test func aSquashConflictLeavesNoMergeState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try conflicting(fixture)
        let repository = try fixture.open()
        #expect(try await repository.merge("refs/heads/topic", mode: .squash) == .conflicts(["a.txt"]))
        #expect(try await repository.snapshot().state == .clean)
        #expect(try await repository.status().first { $0.path == "a.txt" }?.isConflicted == true)
    }
}

@Suite struct CherryPickTests {
    /// `topic` has three commits; the second conflicts with `main`.
    private static func build(_ fixture: Fixture) throws {
        try fixture.commit("a.txt", "base\n", message: "Base")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        try fixture.commit("b.txt", "one\n", message: "One")
        try fixture.commit("a.txt", "topic\n", message: "Two")
        try fixture.commit("c.txt", "three\n", message: "Three")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.commit("a.txt", "main\n", message: "Main")
    }

    private static func ids(_ fixture: Fixture, _ revisions: String...) throws -> [OID] {
        try revisions.map { try #require(OID(hex: fixture.git("rev-parse", $0))) }
    }

    @Test func picksKeepTheirAuthorAndMessage() async throws {
        let (ours, git) = try Fixture.twins(Self.build)
        defer { ours.remove(); git.remove() }
        // Picked by someone else than the author.
        for fixture in [ours, git] {
            try fixture.git("config", "user.name", "Picker")
            try fixture.git("config", "user.email", "picker@example.com")
        }

        let outcome = try await ours.open().cherryPick(Self.ids(ours, "topic~2", "topic"))
        try git.git("cherry-pick", "topic~2", "topic")
        #expect(outcome == .finished)
        #expect(try ours.contentLog() == git.contentLog())
        #expect(try ours.logFormat("%cn", "-1") == ["Picker"])
        #expect(try ours.parentCounts() == [1, 1, 1, 0])
        #expect(try await ours.open().snapshot().state == .clean)
    }

    @Test func aConflictStopsTheSequenceAndContinues() async throws {
        let (ours, git) = try Fixture.twins(Self.build)
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()
        let ids = try Self.ids(ours, "topic~2", "topic~1", "topic")

        let outcome = try await repository.cherryPick(ids)
        #expect(throws: (any Error).self) { try git.git("cherry-pick", "topic~2", "topic~1", "topic") }
        #expect(outcome == .stopped(at: ids[1], conflicts: ["a.txt"]))
        #expect(try await repository.snapshot().state == .cherryPicking)
        #expect(try ours.git("status", "--porcelain") == git.git("status", "--porcelain"))
        #expect(try ours.contentLog() == git.contentLog())

        let operation = try #require(try await repository.ongoingOperation())
        #expect(operation.kind == .cherryPick)
        #expect(operation.commit == ids[1])
        #expect(operation.summary == "Two")
        #expect(operation.queued == 1)

        for fixture in [ours, git] {
            try fixture.write("resolved\n", to: "a.txt")
            try fixture.git("add", "a.txt")
        }
        #expect(try await repository.continueOperation() == .finished)
        try git.git("-c", "core.editor=true", "cherry-pick", "--continue")

        #expect(try ours.contentLog() == git.contentLog())
        #expect(try await repository.snapshot().state == .clean)
        #expect(!ours.fileExists(".git/sequencer"))
    }

    @Test func gitCanResumeAStoppedSequence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build(fixture)
        let repository = try fixture.open()
        _ = try await repository.cherryPick(Self.ids(fixture, "topic~2", "topic~1", "topic"))

        try fixture.write("resolved\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.git("-c", "core.editor=true", "cherry-pick", "--continue")
        #expect(try fixture.logFormat("%s") == ["Three", "Two", "One", "Main", "Base"])
    }

    @Test func skipLeavesOutTheStoppedCommit() async throws {
        let (ours, git) = try Fixture.twins(Self.build)
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()
        _ = try await repository.cherryPick(Self.ids(ours, "topic~2", "topic~1", "topic"))
        #expect(throws: (any Error).self) { try git.git("cherry-pick", "topic~2", "topic~1", "topic") }

        #expect(try await repository.skipOperation() == .finished)
        try git.git("cherry-pick", "--skip")
        #expect(try ours.contentLog() == git.contentLog())
        #expect(try ours.logFormat("%s") == ["Three", "One", "Main", "Base"])
        #expect(try ours.git("status", "--porcelain") == "")
    }

    @Test func abortReturnsToWhereTheSequenceStarted() async throws {
        let (ours, git) = try Fixture.twins(Self.build)
        defer { ours.remove(); git.remove() }
        let start = try ours.git("rev-parse", "HEAD")
        let repository = try ours.open()
        _ = try await repository.cherryPick(Self.ids(ours, "topic~2", "topic~1", "topic"))
        #expect(throws: (any Error).self) { try git.git("cherry-pick", "topic~2", "topic~1", "topic") }

        try await repository.abortOperation()
        try git.git("cherry-pick", "--abort")
        #expect(try ours.git("rev-parse", "HEAD") == start)
        #expect(try git.git("rev-parse", "HEAD") == start)
        #expect(try ours.git("status", "--porcelain") == "")
        #expect(try ours.textOfFile("a.txt") == "main\n")
        #expect(try await repository.snapshot().state == .clean)
    }

    @Test func aPickWhoseChangesAreThereMakesNoCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build(fixture)
        let repository = try fixture.open()
        let one = try Self.ids(fixture, "topic~2")
        try await repository.cherryPick(one)
        #expect(try await repository.cherryPick(one) == .finished)
        #expect(try fixture.logFormat("%s") == ["One", "Main", "Base"])
    }

    @Test func pickingRefusesStagedChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build(fixture)
        try fixture.write("staged\n", to: "s.txt")
        try fixture.git("add", "s.txt")
        await #expect(throws: GitError.self) {
            try await fixture.open().cherryPick(Self.ids(fixture, "topic~2"))
        }
        #expect(try fixture.logFormat("%s") == ["Main", "Base"])
    }
}

@Suite struct RevertTests {
    @Test func revertingMatchesGit() async throws {
        let (ours, git) = try Fixture.twins { fixture in
            try fixture.commit("a.txt", "one\n", message: "First")
            try fixture.commit("a.txt", "two\n", message: "Second")
            try fixture.commit("b.txt", "b\n", message: "Third")
        }
        defer { ours.remove(); git.remove() }

        let ids = try ["HEAD", "HEAD~1"].map { try #require(OID(hex: ours.git("rev-parse", $0))) }
        #expect(try await ours.open().revert(ids) == .finished)
        try git.git("revert", "--no-edit", "HEAD", "HEAD~1")

        #expect(try ours.logFormat("%T %B") == git.logFormat("%T %B"))
        #expect(try ours.textOfFile("a.txt") == "one\n")
        #expect(!ours.fileExists("b.txt"))
    }

    @Test func aRevertConflictContinuesAndAborts() async throws {
        let (ours, git) = try Fixture.twins { fixture in
            try fixture.commit("a.txt", "one\n", message: "First")
            try fixture.commit("a.txt", "two\n", message: "Second")
            try fixture.commit("a.txt", "three\n", message: "Third")
        }
        defer { ours.remove(); git.remove() }
        let second = try #require(OID(hex: ours.git("rev-parse", "HEAD~1")))
        let repository = try ours.open()

        #expect(try await repository.revert([second]) == .stopped(at: second, conflicts: ["a.txt"]))
        #expect(throws: (any Error).self) { try git.git("revert", "--no-edit", "HEAD~1") }
        #expect(try await repository.snapshot().state == .reverting)
        #expect(try await repository.ongoingOperation()?.kind == .revert)
        #expect(try ours.git("status", "--porcelain") == git.git("status", "--porcelain"))

        for fixture in [ours, git] {
            try fixture.write("one\n", to: "a.txt")
            try fixture.git("add", "a.txt")
        }
        #expect(try await repository.continueOperation() == .finished)
        try git.git("-c", "core.editor=true", "revert", "--continue")
        #expect(try ours.logFormat("%T %B", "-1") == git.logFormat("%T %B", "-1"))

        // Reverting the newest change conflicts too; given up this time.
        let third = try #require(OID(hex: ours.git("rev-parse", "HEAD~1")))
        #expect(try await repository.revert([third]) != .finished)
        try await repository.abortOperation()
        #expect(try ours.git("status", "--porcelain") == "")
        #expect(try await repository.snapshot().state == .clean)
    }
}
