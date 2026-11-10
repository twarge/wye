import Foundation
import GitKit
import Testing

/// Everything the command line git reports about a repository that undo
/// promises to put back: references, `HEAD`, the index, the working tree's
/// status and every file's contents, and the stash list.
private struct GitState: Equatable, CustomStringConvertible {
    var refs: String
    var head: String
    var staged: String
    var status: String
    var files: [String: Data]
    var stashes: String

    var description: String {
        "refs:\n\(refs)\nHEAD: \(head)\nstaged:\n\(staged)\nstatus:\n\(status)\nfiles: \(files.keys.sorted())\nstashes:\n\(stashes)"
    }
}

extension Fixture {
    fileprivate func state() throws -> GitState {
        let symbolic = (try? git("symbolic-ref", "-q", "HEAD")) ?? ""
        let target = (try? git("rev-parse", "-q", "--verify", "HEAD")) ?? "unborn"
        var files: [String: Data] = [:]
        let root = url.standardizedFileURL.path
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            while let path = enumerator.nextObject() as? String {
                if path == ".git" || path.hasPrefix(".git/") {
                    enumerator.skipDescendants()
                    continue
                }
                let full = root + "/" + path
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue {
                    files[path] = FileManager.default.contents(atPath: full)
                }
            }
        }
        return GitState(
            refs: try git("for-each-ref", "--format=%(refname) %(objectname)"),
            head: "\(symbolic) \(target)",
            staged: try git("diff", "--cached"),
            status: try git("status", "--porcelain", "--untracked-files=all"),
            files: files,
            stashes: (try? git("stash", "list", "--format=%H %gs")) ?? ""
        )
    }
}

/// Runs an operation through GitKit with undo recording, then undoes it
/// and compares everything with git's view from before, then redoes it and
/// compares with git's view from after. The record goes through JSON first,
/// as it does when kept across launches.
@discardableResult
private func roundTrip(
    _ fixture: Fixture, _ operation: UndoOperation, _ body: (Repository) async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> UndoRecord {
    let repository = try fixture.open()
    let before = try fixture.state()
    let start = await repository.beginUndoable(operation)
    try await body(repository)
    let finish = await repository.finishUndoable(start)
    guard case .recorded(let recorded) = finish else {
        Issue.record("Expected a record, got \(finish)", sourceLocation: sourceLocation)
        throw FixtureError(message: "No record")
    }
    let record = try JSONDecoder().decode(UndoRecord.self, from: JSONEncoder().encode(recorded))
    #expect(record == recorded, sourceLocation: sourceLocation)
    let after = try fixture.state()
    #expect(after != before, "The operation changed nothing", sourceLocation: sourceLocation)

    #expect(try await repository.undoPreflight(record, .undo) == .ready, sourceLocation: sourceLocation)
    try await repository.applyUndo(record, .undo)
    let undone = try fixture.state()
    #expect(undone == before, "Undo:\n\(undone)\nexpected:\n\(before)", sourceLocation: sourceLocation)

    #expect(try await repository.undoPreflight(record, .redo) == .ready, sourceLocation: sourceLocation)
    try await repository.applyUndo(record, .redo)
    let redone = try fixture.state()
    #expect(redone == after, "Redo:\n\(redone)\nexpected:\n\(after)", sourceLocation: sourceLocation)
    return record
}

/// `main` with two commits, and `topic` from the first with one of its own.
private func twoBranches(_ fixture: Fixture) throws {
    try fixture.write("shared\n", to: "shared.txt")
    try fixture.git("add", "shared.txt")
    try fixture.commit("a.txt", "one\n", message: "One")
    try fixture.git("branch", "topic")
    try fixture.commit("a.txt", "two\n", message: "Two")
    try fixture.git("checkout", "--quiet", "topic")
    try fixture.commit("b.txt", "topic\n", message: "Topic")
    try fixture.git("checkout", "--quiet", "main")
}

@Suite struct UndoTests {
    // MARK: Commits

    @Test func undoingACommitKeepsItsChangesStaged() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "One")
        try fixture.write("two\n", to: "a.txt")
        try fixture.write("new\n", to: "b.txt")
        try fixture.git("add", "a.txt", "b.txt")
        try fixture.write("unstaged\n", to: "c.txt")

        let first = try fixture.git("rev-parse", "HEAD")
        let record = try await roundTrip(fixture, .commit) { _ = try await $0.commit(message: "Two") }
        try await fixture.open().applyUndo(record, .undo)
        #expect(try fixture.git("rev-parse", "HEAD") == first)
        #expect(try fixture.git("diff", "--cached", "--name-only") == "a.txt\nb.txt")
        #expect(try fixture.git("status", "--porcelain") == "M  a.txt\nA  b.txt\n?? c.txt")
    }

    private func recordCommit(_ repository: Repository) async throws -> UndoRecord {
        let start = await repository.beginUndoable(.commit)
        try await repository.commit(message: "Two")
        guard case .recorded(let record) = await repository.finishUndoable(start) else {
            throw FixtureError(message: "No record")
        }
        return record
    }

    @Test func undoingTheFirstCommitLeavesTheBranchUnborn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("one\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try await roundTrip(fixture, .commit) { _ = try await $0.commit(message: "First") }
    }

    @Test func undoingAnAmendRestoresThePreviousCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "One")
        try fixture.commit("a.txt", "two\n", message: "Two")
        try fixture.write("three\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try await roundTrip(fixture, .amend) { _ = try await $0.amend(message: "Two, amended") }
    }

    @Test func undoingACheckoutGoesBackAndKeepsLocalChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.write("local\n", to: "shared.txt")
        try fixture.write("untracked\n", to: "u.txt")
        try await roundTrip(fixture, .checkout) { try await $0.checkOut(branch: "refs/heads/topic") }
    }

    @Test func undoingADetachedCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        let first = try OID(hex: fixture.git("rev-parse", "main~1"))!
        try await roundTrip(fixture, .checkout) { try await $0.checkOut(commit: first) }
    }

    // MARK: Branches and tags

    @Test func branchesCreatedRenamedAndDeleted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.git("update-ref", "refs/remotes/origin/topic", "topic")
        try fixture.git("config", "remote.origin.url", "https://example.com/r.git")
        try fixture.git("config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
        try fixture.git("branch", "--set-upstream-to=origin/topic", "topic")

        try await roundTrip(fixture, .createBranch) { _ = try await $0.createBranch(named: "feature") }
        let renamed = try await roundTrip(fixture, .renameBranch) {
            _ = try await $0.renameBranch("refs/heads/topic", to: "renamed")
        }
        try await fixture.open().applyUndo(renamed, .undo)
        #expect(try fixture.git("config", "branch.topic.merge") == "refs/heads/topic")
        try await roundTrip(fixture, .deleteBranch) { try await $0.deleteBranch("refs/heads/topic", force: true) }
        // The deleted branch came back with its upstream before the redo deleted it again.
        #expect(throws: (any Error).self) { try fixture.git("config", "branch.topic.merge") }
    }

    @Test func deletingABranchIsUndoneWithItsUpstream() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.git("update-ref", "refs/remotes/origin/topic", "topic")
        try fixture.git("config", "remote.origin.url", "https://example.com/r.git")
        try fixture.git("config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
        try fixture.git("branch", "--set-upstream-to=origin/topic", "topic")
        let repository = try fixture.open()
        let start = await repository.beginUndoable(.deleteBranch)
        try await repository.deleteBranch("refs/heads/topic", force: true)
        guard case .recorded(let record) = await repository.finishUndoable(start) else {
            Issue.record("No record")
            return
        }
        try await repository.applyUndo(record, .undo)
        #expect(try fixture.git("rev-parse", "--abbrev-ref", "topic@{upstream}") == "origin/topic")
    }

    @Test func renamingTheCheckedOutBranch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try await roundTrip(fixture, .renameBranch) { _ = try await $0.renameBranch("refs/heads/main", to: "trunk") }
    }

    @Test func tagsCreatedAndDeleted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        let head = try OID(hex: fixture.git("rev-parse", "HEAD"))!
        try await roundTrip(fixture, .createTag) { _ = try await $0.createTag(named: "v1", at: head) }
        try await roundTrip(fixture, .createTag) {
            _ = try await $0.createTag(named: "v2", at: head, message: "Version two")
        }
        try fixture.git("tag", "-a", "-m", "Annotated", "v3")
        try await roundTrip(fixture, .deleteTag) { try await $0.deleteTag("refs/tags/v3") }
        try await roundTrip(fixture, .deleteTag) { try await $0.deleteTag("refs/tags/v1") }
    }

    // MARK: Merging and rewriting

    @Test func mergesAndFastForwards() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.write("local\n", to: "notes.txt")
        try await roundTrip(fixture, .merge) { _ = try await $0.merge("refs/heads/topic", mode: .alwaysCommit) }

        try fixture.git("checkout", "--quiet", "-b", "behind", "main~1")
        try await roundTrip(fixture, .merge) {
            let outcome = try await $0.merge("refs/heads/main", mode: .fastForwardWhenPossible)
            #expect(outcome != .upToDate)
        }
    }

    @Test func cherryPicksAndReverts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.git("checkout", "--quiet", "topic")
        try fixture.commit("b.txt", "topic two\n", message: "Topic two")
        try fixture.git("checkout", "--quiet", "main")
        let tip = try OID(hex: fixture.git("rev-parse", "topic"))!
        let previous = try OID(hex: fixture.git("rev-parse", "topic~1"))!

        try await roundTrip(fixture, .cherryPick()) { _ = try await $0.cherryPick([previous]) }
        try fixture.git("reset", "--quiet", "--hard", "main")
        try await roundTrip(fixture, .cherryPick(count: 2)) { _ = try await $0.cherryPick([previous, tip]) }
        let head = try OID(hex: fixture.git("rev-parse", "HEAD"))!
        try await roundTrip(fixture, .revert()) { _ = try await $0.revert([head]) }
    }

    @Test func resetsInEachMode() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.commit("c.txt", "c\n", message: "C")
        let target = try OID(hex: fixture.git("rev-parse", "main~2"))!
        try fixture.write("staged\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("unstaged\n", to: "c.txt")
        try fixture.write("new\n", to: "new.txt")
        try fixture.git("add", "new.txt")
        try fixture.write("untracked\n", to: "u.txt")

        for mode in ResetMode.allCases {
            let record = try await roundTrip(fixture, .reset(mode)) { try await $0.reset(to: target, mode: mode) }
            // Each round trip ends redone: step back for the next mode.
            try await fixture.open().applyUndo(record, .undo)
        }
        #expect(try fixture.textOfFile("c.txt") == "unstaged\n")
        #expect(try fixture.textOfFile("new.txt") == "new\n")
        #expect(try fixture.git("show", ":a.txt") == "staged")
    }

    @Test func aHardResetIsUndoneWithTheChangesItThrewAway() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.write("staged\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("unstaged\n", to: "a.txt")
        try fixture.write("gone\n", to: "added.txt")
        try fixture.git("add", "added.txt")
        let target = try OID(hex: fixture.git("rev-parse", "main~1"))!
        let record = try await roundTrip(fixture, .reset(.hard)) { try await $0.reset(to: target, mode: .hard) }
        #expect(record.working?.before.commit != nil)
        try await fixture.open().applyUndo(record, .undo)
        #expect(try fixture.textOfFile("a.txt") == "unstaged\n")
        #expect(try fixture.git("show", ":a.txt") == "staged")
        #expect(try fixture.textOfFile("added.txt") == "gone\n")
    }

    @Test func rebases() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.git("checkout", "--quiet", "topic")
        try await roundTrip(fixture, .rebase) { _ = try await $0.rebase(onto: "refs/heads/main") }
    }

    // MARK: The index

    @Test func stagingAndUnstaging() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.write("changed\n", to: "a.txt")
        try fixture.write("new\n", to: "new.txt")
        try await roundTrip(fixture, .stage) { try await $0.stage(["a.txt"]) }
        try await roundTrip(fixture, .stage) { try await $0.stage(["a.txt", "new.txt"]) }
        try fixture.git("add", "a.txt", "new.txt")
        try await roundTrip(fixture, .unstage) { try await $0.unstage(["a.txt", "new.txt"]) }
    }

    // MARK: Stashes

    @Test func stashesSavedPoppedAppliedAndDropped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.write("older\n", to: "a.txt")
        try fixture.git("stash", "push", "--quiet", "-m", "Older")
        try fixture.write("changed\n", to: "a.txt")
        try fixture.write("staged\n", to: "s.txt")
        try fixture.git("add", "s.txt")
        try fixture.write("untracked\n", to: "u.txt")

        try await roundTrip(fixture, .stashSave(includingUntracked: true)) {
            _ = try await $0.saveStash(message: "Work", options: .includeUntracked)
        }
        let stashes = try await fixture.open().snapshot().stashes
        #expect(stashes.count == 2)
        // Each round trip ends redone: undo it again before the next.
        let applied = try await roundTrip(fixture, .stashApply) { try await $0.applyStash(stashes[0]) }
        try await fixture.open().applyUndo(applied, .undo)
        let popped = try await roundTrip(fixture, .stashPop) { try await $0.popStash(stashes[0]) }
        try await fixture.open().applyUndo(popped, .undo)
        // Dropping the older one, below the top: undo puts it back in its place.
        try await roundTrip(fixture, .stashDrop) { try await $0.dropStash(stashes[1]) }
        try await roundTrip(fixture, .stashDrop) { try await $0.dropStash(stashes[0]) }
    }

    @Test func aDroppedStashKeepsItsDateWhenRestored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.write("work\n", to: "a.txt")
        try fixture.git("stash", "push", "--quiet", "-m", "Work")
        let listed = try fixture.git("stash", "list", "--format=%gd %gs %ci")
        let repository = try fixture.open()
        let stash = try await repository.snapshot().stashes[0]
        let start = await repository.beginUndoable(.stashDrop)
        try await repository.dropStash(stash)
        guard case .recorded(let record) = await repository.finishUndoable(start) else {
            Issue.record("No record")
            return
        }
        try await repository.applyUndo(record, .undo)
        #expect(try fixture.git("stash", "list", "--format=%gd %gs %ci") == listed)
        try fixture.git("stash", "pop", "--quiet")
        #expect(try fixture.textOfFile("a.txt") == "work\n")
    }

    // MARK: Discarding

    @Test func discardsAreUndoneFromTheSavedCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        try fixture.write("staged\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("unstaged\n", to: "a.txt")
        try fixture.write("untracked\n", to: "folder/u.txt")
        try fixture.write("kept\n", to: "other.txt")

        try await roundTrip(fixture, .discard(paths: ["a.txt", "folder/u.txt"])) {
            try await $0.discardChanges(in: ["a.txt", "folder/u.txt"], untracked: .delete)
        }
        try await roundTrip(fixture, .discard()) { try await $0.discardAllChanges(untracked: .delete) }
        try FileManager.default.removeItem(at: fixture.url.appending(path: "a.txt"))
        try await roundTrip(fixture, .discard()) { try await $0.discardAllChanges(untracked: .delete) }
    }

    // MARK: Refusals

    @Test func undoRefusesOnceTheBranchHasMovedOn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "One")
        try fixture.write("two\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        let repository = try fixture.open()
        let record = try await recordCommit(repository)
        try fixture.commit("b.txt", "b\n", message: "Later")
        let before = try fixture.state()
        await #expect(throws: UndoError.self) { try await repository.undoPreflight(record, .undo) }
        await #expect(throws: UndoError.self) { try await repository.applyUndo(record, .undo) }
        #expect(try fixture.state() == before)
    }

    @Test func undoRefusesToOverwriteAFileChangedSince() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        let repository = try fixture.open()
        let start = await repository.beginUndoable(.checkout)
        try await repository.checkOut(branch: "refs/heads/topic")
        guard case .recorded(let record) = await repository.finishUndoable(start) else {
            Issue.record("No record")
            return
        }
        // Undo would remove b.txt, which now has work in it.
        try fixture.write("precious\n", to: "b.txt")
        let before = try fixture.state()
        await #expect(throws: UndoError.changedSince("“b.txt” has changed since.")) {
            try await repository.applyUndo(record, .undo)
        }
        #expect(try fixture.state() == before)

        // A change to a file the undo does not touch is no obstacle.
        try fixture.git("checkout", "--quiet", "--", "b.txt")
        try fixture.write("unrelated\n", to: "elsewhere.txt")
        try await repository.applyUndo(record, .undo)
        #expect(try fixture.textOfFile("elsewhere.txt") == "unrelated\n")
        #expect(try fixture.git("symbolic-ref", "HEAD") == "refs/heads/main")
    }

    @Test func undoRefusesDuringAnOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "base\n", message: "Base")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        try fixture.commit("a.txt", "topic\n", message: "Topic")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.commit("b.txt", "b\n", message: "B")
        let repository = try fixture.open()
        let record = try await {
            let start = await repository.beginUndoable(.createTag)
            _ = try await repository.createTag(named: "t", at: OID(hex: fixture.git("rev-parse", "HEAD"))!)
            guard case .recorded(let record) = await repository.finishUndoable(start) else {
                throw FixtureError(message: "No record")
            }
            return record
        }()
        try fixture.commit("a.txt", "main\n", message: "Main")

        // A merge that stops on a conflict is not recorded: Abort undoes it.
        let start = await repository.beginUndoable(.merge)
        _ = try await repository.merge("refs/heads/topic", mode: .alwaysCommit)
        guard case .notUndoable = await repository.finishUndoable(start) else {
            Issue.record("A stopped merge was recorded")
            return
        }
        await #expect(throws: UndoError.operationInProgress(.merging)) {
            try await repository.applyUndo(record, .undo)
        }
    }

    @Test func undoAsksBeforeTakingOffAPushedCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "One")
        try fixture.write("two\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        let repository = try fixture.open()
        let record = try await recordCommit(repository)
        try fixture.git("update-ref", "refs/remotes/origin/main", "HEAD")
        guard case .needsConfirmation(let message) = try await repository.undoPreflight(record, .undo) else {
            Issue.record("Expected a confirmation")
            return
        }
        #expect(message.contains("origin/main"))
        try await repository.applyUndo(record, .undo)
        #expect(try fixture.git("rev-parse", "HEAD") == fixture.git("rev-parse", "origin/main~1"))
    }

    @Test func undoRefusesWhenTheSavedCopyIsGone() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "One")
        try fixture.write("lost work\n", to: "a.txt")
        let repository = try fixture.open()
        let start = await repository.beginUndoable(.discard())
        try await repository.discardAllChanges(untracked: .delete)
        guard case .recorded(let record) = await repository.finishUndoable(start) else {
            Issue.record("No record")
            return
        }
        try fixture.git("gc", "--quiet", "--prune=now")
        await #expect(throws: UndoError.objectsMissing) { try await repository.applyUndo(record, .undo) }
    }

    @Test func nothingChangedRecordsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoBranches(fixture)
        let repository = try fixture.open()
        let start = await repository.beginUndoable(.merge)
        #expect(try await repository.merge("refs/heads/main", mode: .fastForwardWhenPossible) == .upToDate)
        guard case .unchanged = await repository.finishUndoable(start) else {
            Issue.record("Expected nothing recorded")
            return
        }
    }
}
