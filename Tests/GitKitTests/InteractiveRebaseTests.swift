import Foundation
import GitKit
import Testing

/// Interactive rebases, compared with `git rebase -i` given the same todo
/// list: the same trees, messages, authors and shape.
@Suite struct InteractiveRebaseTests {
    /// `Base` on main, then four commits on `topic`, each to its own file
    /// unless `conflict`, when the third changes the first's file too.
    private static func build(conflict: Bool = false) -> (Fixture) throws -> Void {
        { fixture in
            try fixture.commit("base.txt", "base\n", message: "Base")
            try fixture.git("checkout", "--quiet", "-b", "topic")
            try fixture.commit("a.txt", "a\n", message: "Add a\n\nWhy a.")
            try fixture.commit("b.txt", "b\n", message: "Add b")
            try fixture.commit(conflict ? "a.txt" : "c.txt", "c\n", message: "Add c\n\nThe body of c.")
            try fixture.commit("d.txt", "d\n", message: "Add d")
        }
    }

    /// The commits of `topic` after Base, oldest first.
    private static func commits(_ fixture: Fixture) throws -> [OID] {
        try fixture.logFormat("%H", "main..topic").reversed().compactMap(OID.init(hex:))
    }

    private static func plan(_ fixture: Fixture, _ actions: [(Int, RebaseStep.Action)]) throws -> [RebaseStep] {
        let ids = try commits(fixture)
        return actions.map { RebaseStep(commit: ids[$0.0], action: $0.1) }
    }

    /// Runs ours and git's from Base and compares them.
    private func expectSameAsGit(
        _ actions: [(Int, RebaseStep.Action)], conflict: Bool = false, editorMessage: String? = nil,
        adjust: ([RebaseStep]) -> [RebaseStep] = { $0 }
    ) async throws {
        let (ours, git) = try Fixture.twins(Self.build(conflict: conflict))
        defer { ours.remove(); git.remove() }
        let base = try #require(OID(hex: ours.git("rev-parse", "main")))
        let steps = adjust(try Self.plan(ours, actions))

        #expect(try await ours.open().interactiveRebase(onto: base, steps: steps) == .finished)
        try git.rebaseInteractively("main", todo: steps, message: editorMessage)

        #expect(try ours.fullLog() == git.fullLog())
        #expect(try ours.parentCounts() == git.parentCounts())
        #expect(try ours.git("symbolic-ref", "HEAD") == "refs/heads/topic")
        #expect(try ours.git("status", "--porcelain") == "")
        #expect(try await ours.open().snapshot().state == .clean)
    }

    @Test func reorderMatchesGit() async throws {
        try await expectSameAsGit([(2, .pick), (0, .pick), (3, .pick), (1, .pick)])
    }

    @Test func squashMatchesGit() async throws {
        try await expectSameAsGit([(0, .pick), (1, .squash), (2, .squash), (3, .pick)])
    }

    @Test func fixupMatchesGit() async throws {
        try await expectSameAsGit([(0, .pick), (1, .fixup), (2, .pick), (3, .fixup)])
    }

    @Test func fixupThenSquashMatchesGit() async throws {
        try await expectSameAsGit([(0, .pick), (1, .fixup), (2, .squash), (3, .fixupWithMessage)])
    }

    @Test func fixupWithMessageMatchesGit() async throws {
        try await expectSameAsGit([(0, .pick), (1, .fixup), (2, .fixupWithMessage), (3, .pick)])
    }

    @Test func dropMatchesGit() async throws {
        try await expectSameAsGit([(0, .pick), (1, .drop), (2, .pick), (3, .drop)])
    }

    @Test func rewordMatchesGit() async throws {
        let message = "A better subject\n\nWith a body, too."
        try await expectSameAsGit([(0, .pick), (1, .reword), (2, .pick), (3, .pick)], editorMessage: message) { steps in
            var steps = steps
            steps[1].message = message
            return steps
        }
    }

    @Test func aChosenSquashMessageIsUsed() async throws {
        let message = "Both a and b"
        try await expectSameAsGit([(0, .pick), (1, .squash), (2, .pick), (3, .pick)], editorMessage: message) { steps in
            var steps = steps
            steps[1].message = message
            return steps
        }
    }

    @Test func theProposedSquashMessageIsGits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build()(fixture)
        let todo = try await fixture.open().interactiveRebaseTodo(from: Self.commits(fixture)[0])
        let messages = todo.candidates.map(\.message)
        let combined = SquashMessage.combined(
            first: messages[0], followers: [(.squash, messages[1]), (.fixup, messages[2]), (.squash, messages[3])]
        )
        #expect(combined == "Add a\n\nWhy a.\n\nAdd b\n\nAdd d\n")
        #expect(SquashMessage.combined(first: messages[0], followers: [(.fixup, messages[1])]) == messages[0])
    }

    @Test func theTodoListsTheCommitsOldestFirst() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build()(fixture)
        let ids = try Self.commits(fixture)
        let todo = try await fixture.open().interactiveRebaseTodo(from: ids[1])
        #expect(todo.onto == ids[0])
        #expect(todo.candidates.map(\.id) == Array(ids[1...]))
        #expect(todo.candidates.map(\.commit.summary) == ["Add b", "Add c", "Add d"])
        #expect(todo.autosquashed == nil)
        #expect(todo.skippedMerges == 0)
    }

    // MARK: Autosquash

    private static func buildFixups(_ fixture: Fixture) throws {
        try fixture.commit("base.txt", "base\n", message: "Base")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        try fixture.commit("a.txt", "a\n", message: "Add a")
        let b = try fixture.commit("b.txt", "b\n", message: "Add b\n\nWhy b.")
        try fixture.commit("c.txt", "c\n", message: "Add c")
        try fixture.commit("a.txt", "a2\n", message: "fixup! Add a")
        try fixture.commit("b.txt", "b2\n", message: "squash! Add b\n\nMore about b.")
        try fixture.commit("b.txt", "b1\n", message: "fixup! \(String(b.prefix(10)))")
        try fixture.commit("a.txt", "a3\n", message: "amend! Add a\n\nA better a.")
        try fixture.commit("c.txt", "c3\n", message: "squash! Add c")
        try fixture.commit("a.txt", "a4\n", message: "fixup! fixup! Add a")
        try fixture.commit("a.txt", "a5\n", message: "fixup! Add")
    }

    @Test func autosquashMatchesGit() async throws {
        let (ours, git) = try Fixture.twins(Self.buildFixups)
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()
        let first = try #require(OID(hex: String(ours.git("rev-list", "--reverse", "main..topic").prefix(40))))
        let todo = try await repository.interactiveRebaseTodo(from: first)
        let steps = try #require(todo.autosquashed)

        // git's own todo, as it proposes it.
        let proposed = try git.proposedTodo("main", "--autosquash")
        #expect(steps.map { "\($0.action.todoWord) \($0.commit.hex)" } == proposed)

        #expect(try await repository.interactiveRebase(onto: todo.onto, steps: steps) == .finished)
        try git.rebaseInteractively("main", todo: steps)
        #expect(try ours.fullLog() == git.fullLog())
        #expect(try ours.logFormat("%s") == ["Add c", "Add b", "A better a.", "Base"])
    }

    @Test func fixupCommitsAreNamedAsGitNamesThem() async throws {
        let (ours, git) = try Fixture.twins { fixture in
            try fixture.commit("a.txt", "a\n", message: "Add a\n\nBody.")
            try fixture.commit("b.txt", "b\n", message: "Add b")
            try fixture.write("a2\n", to: "a.txt")
            try fixture.git("add", "a.txt")
        }
        defer { ours.remove(); git.remove() }
        let target = try #require(OID(hex: ours.git("rev-parse", "HEAD~1")))
        try await ours.open().commitFixup(.fixup, for: target)
        try git.git("commit", "--quiet", "--fixup", "HEAD~1")
        #expect(try ours.logFormat("%T %B") == git.logFormat("%T %B"))

        await #expect(throws: FixupError.nothingStaged) { try await ours.open().commitFixup(.squash, for: target) }
        try ours.write("a3\n", to: "a.txt")
        try ours.git("add", "a.txt")
        try await ours.open().commitFixup(.squash, for: target, details: "Why.")
        #expect(try ours.git("log", "-1", "--format=%B") == "squash! Add a\n\nWhy.")
    }

    // MARK: Conflicts

    @Test func aConflictStopsAndContinuesAfterQuitting() async throws {
        let (ours, git) = try Fixture.twins(Self.build(conflict: true))
        defer { ours.remove(); git.remove() }
        let base = try #require(OID(hex: ours.git("rev-parse", "main")))
        // c changes a.txt, which without a is not there: a conflict.
        let steps = try Self.plan(ours, [(1, .pick), (2, .pick), (3, .squash), (0, .drop)])
        let stopped = steps[1].commit

        let outcome = try await ours.open().interactiveRebase(onto: base, steps: steps)
        #expect(throws: (any Error).self) { try git.rebaseInteractively("main", todo: steps) }
        #expect(outcome == .stopped(at: stopped, conflicts: ["a.txt"]))
        #expect(try ours.git("status").contains("interactive rebase in progress"))

        // A new instance, as after the app quits, carries on from the files.
        let reopened = try ours.open()
        #expect(try await reopened.snapshot().state == .rebasing)
        let operation = try #require(try await reopened.ongoingOperation())
        #expect(operation.commit == stopped)
        #expect(operation.summary == "Add c")
        #expect(operation.step == 2)
        #expect(operation.total == 3)
        #expect(operation.queued == 1)
        await #expect(throws: BranchingError.unresolvedConflicts) { try await reopened.continueOperation() }

        for fixture in [ours, git] {
            try fixture.write("resolved\n", to: "a.txt")
            try fixture.git("add", "a.txt")
        }
        #expect(try await ours.open().continueOperation() == .finished)
        try git.git("-c", "core.editor=true", "rebase", "--continue")

        #expect(try ours.fullLog() == git.fullLog())
        #expect(try ours.git("symbolic-ref", "HEAD") == "refs/heads/topic")
        #expect(try ours.git("status", "--porcelain") == "")
        #expect(!ours.fileExists(".git/rebase-merge"))
    }

    @Test func aConflictInASquashContinuesIntoTheSameCommit() async throws {
        let (ours, git) = try Fixture.twins(Self.build(conflict: true))
        defer { ours.remove(); git.remove() }
        let base = try #require(OID(hex: ours.git("rev-parse", "main")))
        // Squashing c into b conflicts: b's tree has no a.txt from a, which is dropped.
        let steps = try Self.plan(ours, [(0, .drop), (1, .pick), (2, .squash), (3, .pick)])

        let outcome = try await ours.open().interactiveRebase(onto: base, steps: steps)
        #expect(throws: (any Error).self) { try git.rebaseInteractively("main", todo: steps) }
        guard case .stopped = outcome else {
            Issue.record("Expected a conflict, got \(outcome)")
            return
        }
        for fixture in [ours, git] {
            try fixture.write("resolved\n", to: "a.txt")
            try fixture.git("add", "a.txt")
        }
        #expect(try await ours.open().continueOperation() == .finished)
        try git.git("-c", "core.editor=true", "rebase", "--continue")
        #expect(try ours.fullLog() == git.fullLog())
        #expect(try ours.logFormat("%s") == ["Add d", "Add b", "Base"])
    }

    @Test func skipLeavesOutTheStoppedCommit() async throws {
        let (ours, git) = try Fixture.twins(Self.build(conflict: true))
        defer { ours.remove(); git.remove() }
        let base = try #require(OID(hex: ours.git("rev-parse", "main")))
        let steps = try Self.plan(ours, [(2, .pick), (0, .pick), (1, .pick), (3, .pick)])

        _ = try await ours.open().interactiveRebase(onto: base, steps: steps)
        #expect(throws: (any Error).self) { try git.rebaseInteractively("main", todo: steps) }
        #expect(try await ours.open().skipOperation() == .finished)
        try git.git("rebase", "--skip")
        #expect(try ours.fullLog() == git.fullLog())
    }

    @Test func abortRestoresEverything() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build(conflict: true)(fixture)
        try fixture.write("untracked\n", to: "u.txt")
        let original = try fixture.git("rev-parse", "HEAD")
        let reflog = try fixture.git("reflog", "show", "topic")
        let base = try #require(OID(hex: fixture.git("rev-parse", "main")))
        let steps = try Self.plan(fixture, [(2, .pick), (0, .pick), (1, .pick), (3, .pick)])

        guard case .stopped = try await fixture.open().interactiveRebase(onto: base, steps: steps) else {
            Issue.record("Expected a conflict")
            return
        }
        try await fixture.open().abortOperation()
        #expect(try fixture.git("rev-parse", "HEAD") == original)
        #expect(try fixture.git("symbolic-ref", "HEAD") == "refs/heads/topic")
        #expect(try fixture.git("reflog", "show", "topic") == reflog)
        #expect(try fixture.textOfFile("a.txt") == "c\n")
        #expect(try fixture.git("status", "--porcelain") == "?? u.txt")
        #expect(!fixture.fileExists(".git/rebase-merge"))
        #expect(try await fixture.open().snapshot().state == .clean)
    }

    @Test func gitCanAbortOneStoppedHere() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build(conflict: true)(fixture)
        let original = try fixture.git("rev-parse", "HEAD")
        let base = try #require(OID(hex: fixture.git("rev-parse", "main")))
        let steps = try Self.plan(fixture, [(2, .pick), (0, .pick), (1, .pick), (3, .pick)])
        _ = try await fixture.open().interactiveRebase(onto: base, steps: steps)

        try fixture.git("rebase", "--abort")
        #expect(try fixture.git("rev-parse", "HEAD") == original)
        #expect(try fixture.git("symbolic-ref", "HEAD") == "refs/heads/topic")
        #expect(try await fixture.open().snapshot().state == .clean)
    }

    // MARK: Recovery and refusals

    @Test func theOldTipStaysInTheReflogAndOrigHead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build()(fixture)
        let original = try fixture.git("rev-parse", "HEAD")
        let base = try #require(OID(hex: fixture.git("rev-parse", "main")))
        let steps = try Self.plan(fixture, [(1, .pick), (0, .pick), (2, .pick), (3, .pick)])
        _ = try await fixture.open().interactiveRebase(onto: base, steps: steps)

        #expect(try fixture.git("rev-parse", "ORIG_HEAD") == original)
        #expect(try fixture.git("rev-parse", "topic@{1}") == original)
        #expect(try fixture.git("reflog", "-1", "--format=%gs", "topic").hasPrefix("rebase (finish): refs/heads/topic onto"))
    }

    @Test func aFinishedRebaseIsUndoneLikeAnyOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build()(fixture)
        let original = try fixture.git("rev-parse", "HEAD")
        let repository = try fixture.open()
        let base = try #require(OID(hex: fixture.git("rev-parse", "main")))
        let steps = try Self.plan(fixture, [(1, .pick), (0, .squash), (2, .drop), (3, .pick)])

        let start = await repository.beginUndoable(.rebase)
        _ = try await repository.interactiveRebase(onto: base, steps: steps)
        guard case .recorded(let record) = await repository.finishUndoable(start) else {
            Issue.record("The rebase was not recorded")
            return
        }
        try await repository.applyUndo(record, .undo)
        #expect(try fixture.git("rev-parse", "HEAD") == original)
        #expect(try fixture.git("status", "--porcelain") == "")
    }

    @Test func aRebaseFinishedAfterAConflictCanBeUndone() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build(conflict: true)(fixture)
        let original = try fixture.git("rev-parse", "HEAD")
        let repository = try fixture.open()
        let base = try #require(OID(hex: fixture.git("rev-parse", "main")))
        let steps = try Self.plan(fixture, [(1, .pick), (2, .pick), (3, .pick), (0, .drop)])
        _ = try await repository.interactiveRebase(onto: base, steps: steps)
        try fixture.write("resolved\n", to: "a.txt")
        try fixture.git("add", "a.txt")

        let start = try #require(await repository.resumedRebaseUndoStart())
        #expect(try await repository.continueOperation() == .finished)
        guard case .recorded(let record) = await repository.finishUndoable(start) else {
            Issue.record("The finished rebase was not recorded")
            return
        }
        try await repository.applyUndo(record, .undo)
        #expect(try fixture.git("rev-parse", "HEAD") == original)
        #expect(try fixture.git("symbolic-ref", "HEAD") == "refs/heads/topic")
        #expect(try fixture.git("status", "--porcelain") == "")
        #expect(try await repository.resumedRebaseUndoStart() == nil)
    }

    @Test func refusesLocalChangesAndBadPlans() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.build()(fixture)
        let base = try #require(OID(hex: fixture.git("rev-parse", "main")))
        let repository = try fixture.open()

        let squashFirst = try Self.plan(fixture, [(0, .squash), (1, .pick)])
        await #expect(throws: InteractiveRebaseError.nothingToMeldInto(subject: "Add a")) {
            try await repository.interactiveRebase(onto: base, steps: squashFirst)
        }
        try fixture.write("changed\n", to: "a.txt")
        await #expect(throws: GitError.self) {
            try await repository.interactiveRebase(onto: base, steps: Self.plan(fixture, [(0, .pick)]))
        }
        #expect(try await repository.snapshot().state == .clean)
    }

    @Test func fromTheFirstCommitMatchesGitsRoot() async throws {
        let (ours, git) = try Fixture.twins(Self.build())
        defer { ours.remove(); git.remove() }
        let root = try #require(OID(hex: ours.git("rev-parse", "main")))
        let todo = try await ours.open().interactiveRebaseTodo(from: root)
        #expect(todo.onto == nil)
        var steps = todo.plainSteps
        steps.swapAt(0, 1)
        steps[2].action = .squash

        #expect(try await ours.open().interactiveRebase(onto: nil, steps: steps) == .finished)
        try git.rebaseInteractively("--root", todo: steps)
        #expect(try ours.fullLog() == git.fullLog())
        #expect(try ours.parentCounts() == git.parentCounts())
    }

    // MARK: Rebase onto

    @Test func rebaseOntoMatchesGit() async throws {
        let build: (Fixture) throws -> Void = { fixture in
            try fixture.commit("base.txt", "base\n", message: "Base")
            try fixture.git("checkout", "--quiet", "-b", "feature")
            try fixture.commit("f.txt", "f\n", message: "Feature work")
            try fixture.git("checkout", "--quiet", "-b", "topic")
            try fixture.commit("t1.txt", "1\n", message: "Topic one")
            try fixture.commit("t2.txt", "2\n", message: "Topic two")
            try fixture.git("checkout", "--quiet", "main")
            try fixture.commit("m.txt", "m\n", message: "Main moves on")
            try fixture.git("checkout", "--quiet", "topic")
        }
        let (ours, git) = try Fixture.twins(build)
        defer { ours.remove(); git.remove() }

        #expect(try await ours.open().rebase(onto: "refs/heads/main", upstream: "refs/heads/feature") == .finished)
        try git.git("rebase", "--quiet", "--onto", "main", "feature")

        #expect(try ours.fullLog() == git.fullLog())
        #expect(try ours.logFormat("%s") == ["Topic two", "Topic one", "Main moves on", "Base"])
        #expect(try ours.git("symbolic-ref", "HEAD") == "refs/heads/topic")
        #expect(try ours.git("status", "--porcelain") == "")
    }

    // MARK: Editing an earlier commit

    @Test func editingAnEarlierMessageMatchesGit() async throws {
        let (ours, git) = try Fixture.twins(Self.build())
        defer { ours.remove(); git.remove() }
        try ours.write("staged\n", to: "d.txt")
        try ours.git("add", "d.txt")
        let target = try Self.commits(ours)[1]
        let message = "Add b, properly\n\nNow with a body."

        try await ours.open().editCommit(target, message: message)
        var steps = try Self.plan(git, [(0, .pick), (1, .reword), (2, .pick), (3, .pick)])
        steps[1].message = message
        try git.rebaseInteractively("main", todo: steps, message: message)

        #expect(try ours.fullLog() == git.fullLog())
        #expect(try ours.parentCounts() == git.parentCounts())
        // The index and files are left as they were.
        #expect(try ours.git("status", "--porcelain") == "M  d.txt")
        #expect(try ours.git("rev-parse", "ORIG_HEAD") == git.git("rev-parse", "ORIG_HEAD"))
    }

    @Test func editingAnEarlierAuthorMatchesGit() async throws {
        let (ours, git) = try Fixture.twins(Self.build())
        defer { ours.remove(); git.remove() }
        let target = try Self.commits(ours)[0]
        let date = try #require(ISO8601DateFormatter().date(from: "2025-05-06T07:08:09+02:00"))
        let author = Signature(
            name: "Someone Else", email: "else@example.com", date: date, timeZone: try #require(TimeZone(secondsFromGMT: 7200))
        )

        try await ours.open().editCommit(target, author: author)
        let todo = try Self.commits(git).enumerated().map { "\($0.offset == 0 ? "edit" : "pick") \($0.element.hex)\n" }.joined()
        try git.rebaseInteractively("main", todoText: todo)
        try git.git("commit", "--quiet", "--amend", "--no-edit", "--author=Someone Else <else@example.com>",
                    "--date=2025-05-06T07:08:09+02:00")
        try git.git("rebase", "--continue")

        #expect(try ours.fullLog() == git.fullLog())
        #expect(try ours.git("log", "-1", "--format=%an <%ae> %ai", "HEAD~3") == "Someone Else <else@example.com> 2025-05-06 07:08:09 +0200")
    }

    @Test func editingKeepsMergesAfterTheCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "a\n", message: "Add a")
        try fixture.commit("b.txt", "b\n", message: "Add b")
        try fixture.git("checkout", "--quiet", "-b", "side", "HEAD~1")
        try fixture.commit("s.txt", "s\n", message: "Side")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.commit("c.txt", "c\n", message: "Add c")
        try fixture.git("merge", "--quiet", "--no-ff", "-m", "Merge side", "side")
        func firstParents(_ format: String) throws -> [String] {
            try fixture.git("log", "--first-parent", "--format=\(format)").split(separator: "\n").map(String.init)
        }
        let trees = try firstParents("%T")
        let target = try #require(OID(hex: fixture.git("rev-parse", "HEAD~2")))

        try await fixture.open().editCommit(target, message: "Add b again")
        #expect(try firstParents("%T") == trees)
        #expect(try firstParents("%s") == ["Merge side", "Add c", "Add b again", "Add a"])
        #expect(try firstParents("%H %P").map { $0.split(separator: " ").count - 1 } == [2, 1, 1, 0])
        // The side branch was not built on the edited commit, so it stays.
        #expect(try fixture.git("rev-parse", "HEAD^2") == fixture.git("rev-parse", "side"))
    }

    @Test func editingRefusesCommitsOutsideTheBranch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "a\n", message: "Add a")
        try fixture.git("checkout", "--quiet", "-b", "side")
        let side = try #require(OID(hex: fixture.commit("s.txt", "s\n", message: "Side")))
        try fixture.git("checkout", "--quiet", "main")
        let repository = try fixture.open()
        await #expect(throws: EditCommitError.notInHistory) { try await repository.editCommit(side, message: "x") }
        let head = try #require(OID(hex: fixture.git("rev-parse", "HEAD")))
        await #expect(throws: EditCommitError.emptyMessage) { try await repository.editCommit(head, message: "  ") }
    }
}

extension Fixture {
    /// Every commit's tree, author and whole message, newest first.
    func fullLog(_ revision: String = "HEAD") throws -> [String] {
        try git("log", "--format=%T %an <%ae> %ad%n%B%n--", revision).components(separatedBy: "\n")
    }

    /// Runs `git rebase -i` with `todo` as its todo list and, for anything it
    /// asks to edit, `message` as the message, or what it proposes when nil.
    func rebaseInteractively(_ base: String, todo steps: [RebaseStep], message: String? = nil) throws {
        let todo = steps.map { "\($0.action.todoWord) \($0.commit.hex)\n" }.joined()
        try rebaseInteractively(base, todoText: todo, message: message)
    }

    func rebaseInteractively(_ base: String, todoText: String, message: String? = nil) throws {
        let tools = url.appending(path: ".git/test-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let todoFile = tools.appending(path: "todo")
        try todoText.write(to: todoFile, atomically: true, encoding: .utf8)
        let sequenceEditor = try script(in: tools, named: "sequence", "cp '\(todoFile.path)' \"$1\"")
        var editor = "true"
        if let message {
            let messageFile = tools.appending(path: "message")
            try message.write(to: messageFile, atomically: true, encoding: .utf8)
            editor = try script(in: tools, named: "editor", "cp '\(messageFile.path)' \"$1\"")
        }
        _ = try Self.run(
            ["-c", "sequence.editor=\(sequenceEditor)", "-c", "core.editor=\(editor)",
             "rebase", "--quiet", "-i", "--empty=drop", base],
            in: url
        )
    }

    /// The todo list `git rebase -i` proposes, as action and full hash.
    func proposedTodo(_ base: String, _ options: String...) throws -> [String] {
        let tools = url.appending(path: ".git/test-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let copy = tools.appending(path: "proposed")
        // Keeps a copy and empties the list, so git does nothing.
        let editor = try script(in: tools, named: "keep", "cp \"$1\" '\(copy.path)'; : > \"$1\"")
        _ = try? Self.run(["-c", "sequence.editor=\(editor)", "-c", "rebase.abbreviateCommands=false",
                           "rebase", "-i", "--no-autostash"] + options + [base], in: url)
        let text = try String(contentsOf: copy, encoding: .utf8)
        return try text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.map { line in
            var words = line.split(separator: " ")
            let action = words[0] == "fixup" && words.count > 2 && words[1] == "-C" ? "fixup -C" : String(words[0])
            if action == "fixup -C" { words.remove(at: 1) }
            return "\(action) \(try git("rev-parse", String(words[1])))"
        }
    }

    private func script(in directory: URL, named name: String, _ body: String) throws -> String {
        let file = directory.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }
}
