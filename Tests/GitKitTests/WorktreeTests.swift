import Foundation
import GitKit
import Testing

/// Linked worktrees, compared with `git worktree`.
@Suite struct WorktreeTests {
    let fixture: Fixture
    /// Where the worktrees go, beside the repository.
    let folder: URL

    init() throws {
        fixture = try Fixture()
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.commit("a.txt", "two\n", message: "Second")
        folder = fixture.url.appendingPathExtension("worktrees")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func remove() {
        fixture.remove()
        try? FileManager.default.removeItem(at: folder)
    }

    private func real(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// `git worktree list --porcelain`, as one record per worktree.
    private func porcelain(_ fixture: Fixture) throws -> [[String: String]] {
        try fixture.git("worktree", "list", "--porcelain").components(separatedBy: "\n\n").map { record in
            var fields: [String: String] = [:]
            for line in record.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                fields[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
            }
            return fields
        }
    }

    @Test func listsAddsAndOpensWorktreesAsGitDoes() async throws {
        defer { remove() }
        let repository = try fixture.open()
        try fixture.git("branch", "feature")
        let first = try fixture.git("rev-parse", "HEAD~1")

        try await repository.addWorktree(at: folder.appending(path: "feature"), target: .branch("refs/heads/feature"))
        try await repository.addWorktree(at: folder.appending(path: "topic"), target: .newBranch("topic", at: OID(hex: first)!))
        try await repository.addWorktree(at: folder.appending(path: "look"), target: .detached(OID(hex: first)!))

        let records = try porcelain(fixture)
        let listed = try await repository.worktrees()
        #expect(listed.count == records.count)
        for worktree in listed {
            let record = try #require(records.first { real(URL(filePath: $0["worktree"]!)) == real(URL(filePath: worktree.path)) })
            #expect(worktree.head?.target?.hex == record["HEAD"])
            #expect(worktree.head?.branchName == record["branch"])
            #expect((worktree.head.map { if case .detached = $0 { true } else { false } } ?? false) == (record["detached"] != nil))
        }
        #expect(listed.first?.isMain == true)
        #expect(listed.filter(\.isCurrent).map(\.isMain) == [true])
        #expect(Set(listed.map(\.name)) == ["", "feature", "topic", "look"])
        #expect(listed.first?.name == "")
        // No branch was left behind for the detached one.
        #expect(try fixture.git("branch", "--format=%(refname:short)").split(separator: "\n") == ["feature", "main", "topic"])

        // A worktree opens as a repository, commits there, and sees the others.
        let topic = try Repository(at: folder.appending(path: "topic"))
        let topicFixture = Fixture(existing: folder.appending(path: "topic"))
        try topicFixture.write("three\n", to: "a.txt")
        try await topic.stage(["a.txt"])
        let commit = try await topic.commit(message: "From the worktree")
        #expect(try fixture.git("rev-parse", "topic") == commit.hex)
        #expect(try fixture.git("rev-parse", "main") != commit.hex)
        let fromTopic = try await topic.worktrees()
        #expect(fromTopic.filter(\.isCurrent).map(\.name) == ["topic"])
        #expect(fromTopic.first?.isMain == true)
        #expect(real(URL(filePath: fromTopic[0].path)) == real(fixture.url))

        // Branches know where they are checked out.
        let branches = try await repository.snapshot().branches
        #expect(branches.first { $0.name == "feature" }?.worktreePath.map { real(URL(filePath: $0)) } == real(folder.appending(path: "feature")))
        #expect(branches.first { $0.name == "main" }?.worktreePath == nil)
        let fromTopicBranches = try await topic.snapshot().branches
        #expect(fromTopicBranches.first { $0.name == "main" }?.worktreePath != nil)
    }

    @Test func refusesABranchCheckedOutElsewhere() async throws {
        defer { remove() }
        let repository = try fixture.open()
        try fixture.git("worktree", "add", "--quiet", folder.appending(path: "feature").path, "-b", "feature")

        let refused = folder.appending(path: "again")
        do {
            try await repository.addWorktree(at: refused, target: .branch("refs/heads/feature"))
            Issue.record("Adding a worktree for a branch checked out elsewhere succeeded.")
        } catch let error as WorktreeError {
            guard case .branchCheckedOut(let branch, let path) = error else { throw error }
            #expect(branch == "feature")
            #expect(real(URL(filePath: path)) == real(folder.appending(path: "feature")))
            #expect(error.localizedDescription.contains("feature"))
        }
        #expect(!FileManager.default.fileExists(atPath: refused.path))
        // git refuses it too.
        #expect(throws: (any Error).self) { try fixture.git("worktree", "add", "--quiet", refused.path, "feature") }
        // And checking it out or deleting it here is refused, saying where.
        await #expect(throws: WorktreeError.self) { try await repository.checkOut(branch: "refs/heads/feature") }
        await #expect(throws: WorktreeError.self) { try await repository.deleteBranch("refs/heads/feature", force: true) }
        await #expect(throws: WorktreeError.self) {
            try await repository.addWorktree(at: refused, target: .branch("refs/heads/main"))
        }
    }

    /// Deleting a branch a worktree has goes worktree first, then branch:
    /// once the worktree is removed, its branch is free to delete, and the
    /// commits only it has are counted as git counts them.
    @Test func deletesABranchOnceItsWorktreeIsRemoved() async throws {
        defer { remove() }
        let repository = try fixture.open()
        let path = folder.appending(path: "feature")
        try fixture.git("worktree", "add", "--quiet", path.path, "-b", "feature")
        let worktree = Fixture(existing: path)
        try worktree.commit("b.txt", "only here\n", message: "Feature")

        #expect(try await repository.worktreeHolding(branch: "refs/heads/feature")?.name == "feature")
        let listed = try await repository.snapshot().branches.first { $0.id == "refs/heads/feature" }
        #expect(listed?.worktreePath.map { real(URL(filePath: $0)) } == real(path))
        #expect(try await repository.unmergedCommitCount(of: "refs/heads/feature") == 1)
        await #expect(throws: WorktreeError.self) { try await repository.deleteBranch("refs/heads/feature", force: true) }

        try await repository.removeWorktree("feature", force: true)
        #expect(try await repository.worktreeHolding(branch: "refs/heads/feature") == nil)
        #expect(try await repository.snapshot().branches.first { $0.id == "refs/heads/feature" }?.worktreePath == nil)
        // Its commit is still only on it, so an unforced delete is refused, as `git branch -d` refuses it.
        await #expect(throws: BranchingError.notMerged(branch: "feature", commits: 1)) {
            try await repository.deleteBranch("refs/heads/feature")
        }
        #expect(throws: (any Error).self) { try fixture.git("branch", "-d", "feature") }
        try await repository.deleteBranch("refs/heads/feature", force: true)
        #expect(try fixture.git("branch", "--list", "feature").isEmpty)
    }

    @Test func locksMovesRemovesAndPrunesAsGitDoes() async throws {
        defer { remove() }
        let repository = try fixture.open()
        let path = folder.appending(path: "work")
        try fixture.git("worktree", "add", "--quiet", path.path, "-b", "work")

        try await repository.lockWorktree("work", reason: "On a removable disk")
        #expect(try porcelain(fixture)[1]["locked"] == "On a removable disk")
        var listed = try #require(try await repository.worktrees().last)
        #expect(listed.isLocked && listed.lockReason == "On a removable disk")
        await #expect(throws: WorktreeError.self) { try await repository.removeWorktree("work") }
        try await repository.unlockWorktree("work")
        #expect(try porcelain(fixture)[1]["locked"] == nil)

        let moved = folder.appending(path: "elsewhere/work")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await repository.moveWorktree("work", to: moved)
        #expect(real(URL(filePath: try porcelain(fixture)[1]["worktree"]!)) == real(moved))
        let movedFixture = Fixture(existing: moved)
        #expect(try movedFixture.git("status", "--porcelain").isEmpty)
        #expect(try movedFixture.git("rev-parse", "--abbrev-ref", "HEAD") == "work")
        _ = try Repository(at: moved)

        try movedFixture.write("changed\n", to: "a.txt")
        await #expect(throws: WorktreeError.hasLocalChanges(path: try #require(try await repository.worktrees().last).path)) {
            try await repository.removeWorktree("work")
        }
        try await repository.removeWorktree("work", force: true)
        #expect(try porcelain(fixture).count == 1)
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(!fixture.fileExists(".git/worktrees/work"))

        // A worktree whose folder went is prunable; a locked one stays.
        try fixture.git("worktree", "add", "--quiet", folder.appending(path: "gone").path, "-b", "gone")
        try fixture.git("worktree", "add", "--quiet", folder.appending(path: "kept").path, "-b", "kept")
        try fixture.git("worktree", "lock", folder.appending(path: "kept").path)
        try FileManager.default.removeItem(at: folder.appending(path: "gone"))
        try FileManager.default.removeItem(at: folder.appending(path: "kept"))
        listed = try #require(try await repository.worktrees().first { $0.name == "gone" })
        #expect(listed.isMissing && listed.isPrunable)
        #expect(try porcelain(fixture).first { $0["branch"] == "refs/heads/gone" }?["prunable"] != nil)
        #expect(try await repository.pruneWorktrees() == ["gone"])
        #expect(try porcelain(fixture).map { $0["branch"] } == ["refs/heads/main", "refs/heads/kept"])
        try fixture.git("worktree", "prune")
        #expect(try porcelain(fixture).count == 2)
    }
}
