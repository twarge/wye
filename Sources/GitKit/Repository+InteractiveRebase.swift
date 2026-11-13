import Clibgit2
import Foundation

/// Why an interactive rebase's plan cannot run.
public enum InteractiveRebaseError: Error, Hashable, Sendable, LocalizedError {
    /// A squash or fixup comes before any commit it could join.
    case nothingToMeldInto(subject: String)
    /// The plan names a merge commit, which replaying would flatten.
    case mergeCommit(subject: String)
    /// The plan keeps no commit and there is no base to leave the branch at.
    case emptyHistory
    /// The commit is not part of the current branch's history.
    case notInHistory
    /// A reword or squash was given an empty message.
    case emptyMessage

    public var errorDescription: String? {
        switch self {
        case .nothingToMeldInto(let subject):
            "“\(subject)” is set to squash or fix up, but no commit comes before it to join."
        case .mergeCommit(let subject):
            "“\(subject)” is a merge commit, which an interactive rebase cannot replay."
        case .emptyHistory:
            "The branch would be left with no commits. Keep at least one."
        case .notInHistory:
            "That commit is not part of the current branch’s history."
        case .emptyMessage:
            "A commit message cannot be empty."
        }
    }
}

extension Repository {
    // MARK: Planning

    /// The commits an interactive rebase from `start` replays: `start` and
    /// every commit after it up to `HEAD`, oldest first, leaving out merge
    /// commits as `git rebase -i start^` does.
    public func interactiveRebaseTodo(from start: OID) throws -> RebaseTodo {
        guard let head = try head().target else { throw InteractiveRebaseError.notInHistory }
        var tip = head.raw
        var base = start.raw
        guard head == start || git_graph_descendant_of(pointer, &tip, &base) == 1 else {
            throw InteractiveRebaseError.notInHistory
        }
        let first = try lookupCommit(start)
        defer { git_commit_free(first) }
        let onto = git_commit_parentcount(first) > 0 ? OID(git_commit_parent_id(first, 0)) : nil
        let parents = (0..<git_commit_parentcount(first)).map { git_commit_parent_id(first, $0).pointee }
        return try rebaseTodo(onto: onto, tip: tip, hiding: parents)
    }

    /// The commits an interactive rebase onto `base` replays: those `HEAD`
    /// has and `base` lacks, oldest first, leaving out merge commits, as
    /// `git rebase -i base` lists them. `base` may be on another branch,
    /// which the commits then move onto.
    public func interactiveRebaseTodo(onto base: OID) throws -> RebaseTodo {
        guard let head = try head().target else { throw InteractiveRebaseError.notInHistory }
        var tip = head.raw
        var hidden = base.raw
        let isInHistory = head == base || git_graph_descendant_of(pointer, &tip, &hidden) == 1
        return try rebaseTodo(onto: base, tip: tip, hiding: [hidden], changesBase: !isInHistory)
    }

    /// The commits from `tip` back to, and not including, those reachable
    /// from `hidden`, as an interactive rebase onto `onto` replays them.
    private func rebaseTodo(
        onto: OID?, tip: git_oid, hiding hidden: [git_oid], changesBase: Bool = false
    ) throws -> RebaseTodo {
        var walker: OpaquePointer?
        try check(git_revwalk_new(&walker, pointer))
        defer { git_revwalk_free(walker) }
        git_revwalk_sorting(walker, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_REVERSE.rawValue)
        var tip = tip
        try check(git_revwalk_push(walker, &tip))
        for var commit in hidden {
            try check(git_revwalk_hide(walker, &commit))
        }

        var candidates: [RebaseCandidate] = []
        var merges = 0
        var id = git_oid()
        while git_revwalk_next(&id, walker) == 0 {
            let commit = try lookupCommit(OID(id))
            defer { git_commit_free(commit) }
            if git_commit_parentcount(commit) > 1 {
                merges += 1
                continue
            }
            let message = git_commit_message(commit).map { String(cString: $0) } ?? ""
            candidates.append(RebaseCandidate(commit: Commit(commit), message: message))
        }
        let autosquashed = RebaseTodo.autosquash(candidates) { [self] name in resolveCommitName(name) }
        return RebaseTodo(
            onto: onto, candidates: candidates, skippedMerges: merges, autosquashed: autosquashed, changesBase: changesBase
        )
    }

    // MARK: Running

    /// Rewrites the current branch from `onto` by `steps`, in order, as
    /// `git rebase -i` does with the same todo list: picks replay commits,
    /// rewords give new messages, squashes and fixups meld commits into the
    /// one before, drops leave them out, and a commit that ends up changing
    /// nothing is left out too (git's `--empty=drop`).
    ///
    /// Stops at the first conflict with the repository rebasing, to resume
    /// with `continueOperation()` or `skipOperation()`, or return to where
    /// it started with `abortOperation()`. The plan is kept in the git
    /// directory, so it survives the app quitting part way.
    ///
    /// - Parameter onto: The commit to replay onto; `nil` to start the
    ///   history afresh, as `--root` does.
    @discardableResult
    public func interactiveRebase(onto: OID?, steps: [RebaseStep]) throws -> OperationOutcome {
        try requireNoOperation()
        let signature = try branchingSignature()
        git_signature_free(signature)
        guard let original = try head().target else { throw InteractiveRebaseError.notInHistory }
        try requireCleanTrackedFiles()
        try validate(steps, onto: onto)

        let headName: String? = if case .branch(let name, _) = try head() { name } else { nil }
        // A new history starts from an empty commit, which the first pick
        // takes the place of, as git's `--root` does.
        let placeholder = onto == nil ? try emptyRootCommit() : nil
        let start = try onto ?? placeholder ?? { throw InteractiveRebaseError.emptyHistory }()
        var state = SequencerState(
            headName: headName, originalHead: original, onto: onto,
            steps: steps.map(StoredStep.init), next: 0, stopped: nil, stoppedHead: nil, squash: SquashMessage(),
            placeholder: placeholder
        )
        try writeGitFile("ORIG_HEAD", original.hex + "\n")
        try saveSequencer(state)
        let commit = try lookupCommit(start)
        defer { git_commit_free(commit) }
        try checkOutTree(of: commit)
        try pointDetachedHead(at: start, log: "rebase (start): checkout \(onto?.hex ?? "root")")
        return try runSequencer(&state)
    }

    /// Whether the rebase under way is one `interactiveRebase` started.
    var isInteractiveSequencerActive: Bool {
        FileManager.default.fileExists(atPath: sequencerFile.path)
    }

    func continueSequencer() throws -> OperationOutcome {
        guard try conflictedPaths().isEmpty else { throw BranchingError.unresolvedConflicts }
        let signature = try branchingSignature()
        git_signature_free(signature)
        var state = try loadSequencer()
        if let stopped = state.stopped {
            // Unless the resolution was committed by hand, commit it as the
            // step would have.
            if try head().target == state.stoppedHead {
                try finishStep(stopped, of: &state)
            }
            state.stopped = nil
            state.stoppedHead = nil
        }
        return try runSequencer(&state)
    }

    func skipSequencer() throws -> OperationOutcome {
        var state = try loadSequencer()
        try resetHardToHead()
        removeStepFiles()
        state.stopped = nil
        state.stoppedHead = nil
        return try runSequencer(&state)
    }

    func abortSequencer() throws {
        let state = try loadSequencer()
        let original = try lookupCommit(state.originalHead)
        defer { git_commit_free(original) }
        // The branch itself never moved: put the files and index back as it
        // has them and point HEAD at it again.
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        try check(git_reset(pointer, original, GIT_RESET_HARD, &options))
        if let name = state.headName {
            var reference: OpaquePointer?
            try check(git_reference_symbolic_create(
                &reference, pointer, "HEAD", name, 1, "rebase (abort): returning to \(name)"
            ))
            git_reference_free(reference)
        } else {
            try pointDetachedHead(at: state.originalHead, log: "rebase (abort): returning to \(state.originalHead.hex)")
        }
        removeStepFiles()
        try removeSequencerDirectory()
    }

    func sequencerProgress(conflicts: [String]) -> OngoingOperation {
        guard let state = try? loadSequencer() else {
            return OngoingOperation(
                kind: .rebase, commit: nil, summary: "", step: nil, total: nil, queued: 0, conflictedPaths: conflicts
            )
        }
        let kept = state.steps.indices.filter { state.steps[$0].action != .drop }
        let current = state.stopped
        let id = current.map { state.steps[$0].commit }
        let position = current.flatMap { kept.firstIndex(of: $0) }
        return OngoingOperation(
            kind: .rebase,
            commit: id,
            summary: id.flatMap { try? commit($0).summary } ?? "",
            step: position.map { $0 + 1 },
            total: kept.count,
            queued: kept.filter { $0 >= state.next }.count,
            conflictedPaths: conflicts
        )
    }

    /// What Undo needs to reverse a rebase that stopped part way and is
    /// about to be continued or skipped: the repository as it was before the
    /// rebase began, which was not recorded then. Pass it to
    /// `finishUndoable` once the rebase has finished. `nil` when no rebase
    /// of a branch is under way.
    public func resumedRebaseUndoStart() -> UndoStart? {
        guard RepositoryState(git_repository_state(pointer)) == .rebasing,
              let branch = readGitFile("rebase-merge/head-name"), branch.hasPrefix("refs/heads/"),
              let original = readGitFile("rebase-merge/orig-head").flatMap(OID.init(hex:)),
              var checkpoint = try? undoCheckpoint(for: .rebase, keepingCommit: false),
              let commit = try? lookupCommit(original) else { return nil }
        defer { git_commit_free(commit) }
        // A rebase starts from a clean working copy: its files were the
        // branch's, and the branch was where it began.
        let tree = OID(git_commit_tree_id(commit))
        checkpoint.state = .clean
        checkpoint.head = .symbolic(branch)
        checkpoint.refs[branch] = original
        checkpoint.working = UndoWorkingState(index: tree, workTree: tree, commit: nil)
        return UndoStart(operation: .rebase, checkpoint: .success(checkpoint))
    }

    // MARK: Steps

    private func runSequencer(_ state: inout SequencerState) throws -> OperationOutcome {
        while state.next < state.steps.count {
            let index = state.next
            let step = state.steps[index]
            state.next += 1
            if step.action == .drop { continue }
            do {
                if try fastForward(step, of: &state) {
                    state.squash = SquashMessage()
                    try saveSequencer(state)
                    continue
                }
                try applyStep(step, of: state)
            } catch {
                // Nothing was applied, as when untracked files are in the
                // way: Continue tries the step again.
                state.next = index
                try? saveSequencer(state)
                throw error
            }
            let conflicts = try conflictedPaths()
            if !conflicts.isEmpty {
                state.stopped = index
                state.stoppedHead = try head().target
                try saveSequencer(state)
                try writeStopFiles(for: step)
                return .stopped(at: step.commit, conflicts: conflicts)
            }
            try finishStep(index, of: &state)
            try saveSequencer(state)
        }
        try finishSequencer(state)
        return .finished
    }

    /// Takes a pick whose commit already sits on `HEAD` as it is, as git
    /// does, rather than making a copy of it.
    private func fastForward(_ step: StoredStep, of state: inout SequencerState) throws -> Bool {
        guard step.action == .pick, step.author == nil else { return false }
        let commit = try lookupCommit(step.commit)
        defer { git_commit_free(commit) }
        let parent = git_commit_parentcount(commit) == 1 ? OID(git_commit_parent_id(commit, 0)) : nil
        let head = try currentSequencerHead(state)
        guard parent == head else { return false }
        try checkOutTree(of: commit)
        try pointDetachedHead(at: step.commit, log: "rebase (pick): \(summary(of: commit))")
        return true
    }

    /// Applies a step's changes to the index and files, on top of `HEAD`.
    private func applyStep(_ step: StoredStep, of state: SequencerState) throws {
        let commit = try lookupCommit(step.commit)
        defer { git_commit_free(commit) }
        var options = git_cherrypick_options()
        try check(git_cherrypick_options_init(&options, UInt32(GIT_CHERRYPICK_OPTIONS_VERSION)))
        options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try check(git_cherrypick(pointer, commit, &options))
        // The rebase keeps its own place; a cherry-pick's would hide it.
        try? FileManager.default.removeItem(at: gitDirectory.appending(path: "CHERRY_PICK_HEAD"))
    }

    /// Commits a step's changes, now in the index: a new commit for a pick
    /// or reword, or the commit before amended for a squash or fixup.
    private func finishStep(_ index: Int, of state: inout SequencerState) throws {
        let step = state.steps[index]
        let original = try lookupCommit(step.commit)
        defer { git_commit_free(original) }
        let committer = try branchingSignature()
        defer { git_signature_free(committer) }
        let treeID = try writeIndexTree()
        var tree: OpaquePointer?
        var rawTree = treeID.raw
        try check(git_tree_lookup(&tree, pointer, &rawTree))
        defer { git_tree_free(tree) }
        let originalMessage = git_commit_message(original).map { String(cString: $0) } ?? ""
        let head = try currentSequencerHead(state)

        if step.action.meldsIntoPrevious, let head {
            let previous = try lookupCommit(head)
            defer { git_commit_free(previous) }
            let previousMessage = git_commit_message(previous).map { String(cString: $0) } ?? ""
            state.squash.add(step.action, message: originalMessage) { previousMessage }
            var message = state.squash.message
            if isLastOfRun(index, in: state.steps), let chosen = runMessage(endingAt: index, in: state.steps) {
                message = chosen
            }
            var parents: [OpaquePointer?] = []
            defer { parents.forEach { git_commit_free($0) } }
            for position in 0..<git_commit_parentcount(previous) {
                parents.append(try lookupCommit(OID(git_commit_parent_id(previous, position))))
            }
            let id = try createCommit(
                author: git_commit_author(previous), committer: committer, message: message, tree: tree,
                parents: parents, updatesHead: false
            )
            try pointDetachedHead(at: id, log: "rebase (\(step.action == .squash ? "squash" : "fixup")): \(firstLine(message))")
            removeStepFiles()
            return
        }

        state.squash = SquashMessage()
        let headTree: OID? = try head.map { id in
            let commit = try lookupCommit(id)
            defer { git_commit_free(commit) }
            return OID(git_commit_tree_id(commit))
        }
        let originalParentTree = try parentTree(of: original)
        let wasEmpty = git_commit_parentcount(original) == 1 && OID(git_commit_tree_id(original)) == originalParentTree
        if headTree == treeID && !wasEmpty {
            // Its changes are there already: leave it out, as git does.
            removeStepFiles()
            return
        }
        let message = step.message.map(Self.committedMessage) ?? originalMessage
        var parents: [OpaquePointer?] = []
        defer { parents.forEach { git_commit_free($0) } }
        if let head { parents.append(try lookupCommit(head)) }
        let id: OID
        if let author = step.author {
            let signature = try makeSignature(author)
            defer { git_signature_free(signature) }
            id = try createCommit(
                author: signature, committer: committer, message: message, tree: tree, parents: parents, updatesHead: false
            )
        } else {
            id = try createCommit(
                author: git_commit_author(original), committer: committer, message: message, tree: tree,
                parents: parents, updatesHead: false
            )
        }
        let verb = step.action == .reword ? "reword" : "pick"
        try pointDetachedHead(at: id, log: "rebase (\(verb)): \(firstLine(message))")
        removeStepFiles()
    }

    /// Points the branch at the result and `HEAD` back at the branch.
    private func finishSequencer(_ state: SequencerState) throws {
        let result = try head().target
        let base = state.onto?.hex ?? "root"
        if let name = state.headName {
            if let result {
                var oid = result.raw
                var reference: OpaquePointer?
                try check(git_reference_create(
                    &reference, pointer, name, &oid, 1, "rebase (finish): \(name) onto \(base)"
                ))
                git_reference_free(reference)
            }
            var head: OpaquePointer?
            try check(git_reference_symbolic_create(&head, pointer, "HEAD", name, 1, "rebase (finish): returning to \(name)"))
            git_reference_free(head)
        }
        removeStepFiles()
        try removeSequencerDirectory()
    }

    // MARK: Plans

    private func validate(_ steps: [RebaseStep], onto: OID?) throws {
        var hasCommit = false
        for step in steps where step.action != .drop {
            let commit = try lookupCommit(step.commit)
            defer { git_commit_free(commit) }
            if git_commit_parentcount(commit) > 1 {
                throw InteractiveRebaseError.mergeCommit(subject: summary(of: commit))
            }
            if step.action.meldsIntoPrevious && !hasCommit {
                throw InteractiveRebaseError.nothingToMeldInto(subject: summary(of: commit))
            }
            if step.action == .reword || step.action.meldsIntoPrevious, let message = step.message,
               message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw InteractiveRebaseError.emptyMessage
            }
            hasCommit = true
        }
        if !hasCommit && onto == nil {
            throw InteractiveRebaseError.emptyHistory
        }
    }

    /// Whether no squash or fixup follows the step, passing over drops.
    private func isLastOfRun(_ index: Int, in steps: [StoredStep]) -> Bool {
        let later = steps[(index + 1)...].first { $0.action != .drop }
        return later.map { !$0.action.meldsIntoPrevious } ?? true
    }

    /// The message chosen for the run of squashes and fixups that `index`
    /// ends, if one of them carries it.
    private func runMessage(endingAt index: Int, in steps: [StoredStep]) -> String? {
        var position = index
        while position >= 0, steps[position].action.meldsIntoPrevious || steps[position].action == .drop {
            if steps[position].action != .drop, let message = steps[position].message {
                return Self.committedMessage(message)
            }
            position -= 1
        }
        return nil
    }

    static func committedMessage(_ message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: Helpers

    /// Refuses local changes to tracked files, which replaying would mix in.
    func requireCleanTrackedFiles() throws {
        if try hasChangesToTrackedFiles() {
            throw GitError(
                code: GIT_EUNCOMMITTED.rawValue,
                message: "There are local changes. Commit or stash them before rewriting history."
            )
        }
    }

    /// `HEAD` during the rebase: `nil` until the first commit of a new
    /// history is made, while `HEAD` is still on the original branch.
    private func currentSequencerHead(_ state: SequencerState) throws -> OID? {
        let head = try head().target
        return head == state.placeholder ? nil : head
    }

    /// A commit with no files and no parents, for a new history to start from.
    private func emptyRootCommit() throws -> OID {
        var builder: OpaquePointer?
        try check(git_treebuilder_new(&builder, pointer, nil))
        defer { git_treebuilder_free(builder) }
        var treeID = git_oid()
        try check(git_treebuilder_write(&treeID, builder))
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &treeID))
        defer { git_tree_free(tree) }
        let signature = try branchingSignature()
        defer { git_signature_free(signature) }
        var id = git_oid()
        try check(git_commit_create(&id, pointer, nil, signature, signature, nil, "Start of a new history\n", tree, 0, nil))
        return OID(id)
    }

    func pointDetachedHead(at id: OID, log: String) throws {
        var oid = id.raw
        var reference: OpaquePointer?
        try check(git_reference_create(&reference, pointer, "HEAD", &oid, 1, log))
        git_reference_free(reference)
    }

    private func writeIndexTree() throws -> OID {
        let index = try branchingIndex()
        defer { git_index_free(index) }
        var id = git_oid()
        try check(git_index_write_tree(&id, index))
        return OID(id)
    }

    private func parentTree(of commit: OpaquePointer?) throws -> OID? {
        guard git_commit_parentcount(commit) > 0 else { return nil }
        let parent = try lookupCommit(OID(git_commit_parent_id(commit, 0)))
        defer { git_commit_free(parent) }
        return OID(git_commit_tree_id(parent))
    }

    private func summary(of commit: OpaquePointer?) -> String {
        git_commit_summary(commit).map { String(cString: $0) } ?? ""
    }

    private func firstLine(_ message: String) -> String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }

    func resolveCommitName(_ name: String) -> OID? {
        var object: OpaquePointer?
        guard git_revparse_single(&object, pointer, name) == 0 else { return nil }
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        guard git_object_peel(&commit, object, GIT_OBJECT_COMMIT) == 0 else { return nil }
        defer { git_object_free(commit) }
        return OID(git_object_id(commit))
    }

    // MARK: Files

    private var sequencerDirectory: URL {
        gitDirectory.appending(path: "rebase-merge", directoryHint: .isDirectory)
    }

    private var sequencerFile: URL {
        sequencerDirectory.appending(path: "wye-plan.json")
    }

    private func loadSequencer() throws -> SequencerState {
        try JSONDecoder().decode(SequencerState.self, from: Data(contentsOf: sequencerFile))
    }

    /// Writes the plan, and git's own files beside it so that git sees an
    /// interactive rebase under way, can show it and can abort it.
    private func saveSequencer(_ state: SequencerState) throws {
        let directory = sequencerDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: sequencerFile, options: .atomic)
        func todo(_ steps: ArraySlice<StoredStep>) -> String {
            steps.map { step in
                let subject = (try? commit(step.commit).summary) ?? ""
                return "\(step.action.todoWord) \(step.commit.hex) # \(subject)\n"
            }.joined()
        }
        let doneCount = state.stopped.map { $0 + 1 } ?? state.next
        try writeGitFile("rebase-merge/head-name", (state.headName ?? "detached HEAD") + "\n")
        try writeGitFile("rebase-merge/orig-head", state.originalHead.hex + "\n")
        try writeGitFile("rebase-merge/onto", (state.onto ?? state.originalHead).hex + "\n")
        try writeGitFile("rebase-merge/interactive", "")
        try writeGitFile("rebase-merge/done", todo(state.steps[..<min(doneCount, state.steps.count)]))
        try writeGitFile("rebase-merge/git-rebase-todo", todo(state.steps[min(doneCount, state.steps.count)...]))
        try writeGitFile("rebase-merge/msgnum", "\(doneCount)\n")
        try writeGitFile("rebase-merge/end", "\(state.steps.count)\n")
    }

    /// What git leaves when a step stops: the commit, for `REBASE_HEAD` and
    /// `stopped-sha`.
    private func writeStopFiles(for step: StoredStep) throws {
        try writeGitFile("REBASE_HEAD", step.commit.hex + "\n")
        try writeGitFile("rebase-merge/stopped-sha", step.commit.hex + "\n")
    }

    /// Clears what a step left behind: the cherry-pick's message and the
    /// stopped commit.
    private func removeStepFiles() {
        for name in ["MERGE_MSG", "CHERRY_PICK_HEAD", "REBASE_HEAD", "rebase-merge/stopped-sha"] {
            try? FileManager.default.removeItem(at: gitDirectory.appending(path: name))
        }
    }

    private func removeSequencerDirectory() throws {
        if FileManager.default.fileExists(atPath: sequencerDirectory.path) {
            try FileManager.default.removeItem(at: sequencerDirectory)
        }
    }
}

// MARK: Stored state

/// An interactive rebase under way, as kept in `rebase-merge/wye-plan.json`.
private struct SequencerState: Codable {
    /// The branch being rebased, by full name; `nil` for a detached `HEAD`.
    var headName: String?
    var originalHead: OID
    var onto: OID?
    var steps: [StoredStep]
    /// The first step not yet begun.
    var next: Int
    /// The step that stopped on a conflict.
    var stopped: Int?
    /// `HEAD` when it stopped, to tell whether the resolution was committed by hand.
    var stoppedHead: OID?
    /// The message being built for the current run of squashes and fixups.
    var squash: SquashMessage
    /// For a new history, the empty commit it starts from, which no commit
    /// keeps as a parent.
    var placeholder: OID?
}

private struct StoredStep: Codable {
    struct Author: Codable {
        var name: String
        var email: String
        var date: Date
        var secondsFromGMT: Int
    }

    var commit: OID
    var action: RebaseStep.Action
    var message: String?
    var author: Signature?

    init(_ step: RebaseStep) {
        commit = step.commit
        action = step.action
        message = step.message
        author = step.author
    }

    private enum CodingKeys: String, CodingKey {
        case commit, action, message, author
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commit = try container.decode(OID.self, forKey: .commit)
        action = try container.decode(RebaseStep.Action.self, forKey: .action)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        author = try container.decodeIfPresent(Author.self, forKey: .author).map {
            Signature(name: $0.name, email: $0.email, date: $0.date,
                      timeZone: TimeZone(secondsFromGMT: $0.secondsFromGMT) ?? .gmt)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commit, forKey: .commit)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(author.map {
            Author(name: $0.name, email: $0.email, date: $0.date, secondsFromGMT: $0.timeZone.secondsFromGMT(for: $0.date))
        }, forKey: .author)
    }
}

extension RebaseStep.Action: Codable {}
