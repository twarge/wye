import Clibgit2
import Foundation

/// How `merge` joins another branch into the current one.
public enum MergeMode: Hashable, Sendable, CaseIterable {
    /// Moves the branch forward when it has nothing of its own, and makes a
    /// merge commit otherwise.
    case fastForwardWhenPossible
    /// Always makes a merge commit, even when a fast-forward would do.
    case alwaysCommit
    /// Makes one ordinary commit holding all the other branch's changes,
    /// without recording it as a parent.
    case squash
}

/// What a merge did.
public enum MergeOutcome: Hashable, Sendable {
    /// The current branch already contains the other one.
    case upToDate
    case fastForwarded(to: OID)
    /// A merge commit, or for a squash an ordinary one, was made.
    case committed(OID)
    /// The merge stopped with these files in conflict. A plain merge leaves
    /// the repository merging, to finish with `continueOperation()` or a
    /// commit; a squash leaves only the conflicted index.
    case conflicts([String])
}

/// What a cherry-pick, revert or rebase, or resuming one, did.
public enum OperationOutcome: Hashable, Sendable {
    case finished
    /// Stopped with these files in conflict while applying `commit`.
    case stopped(at: OID, conflicts: [String])
}

/// A merge, rebase, cherry-pick or revert that has stopped part way.
public struct OngoingOperation: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case merge
        case rebase
        case cherryPick
        case revert
    }

    public let kind: Kind
    /// The commit being merged, replayed, picked or reverted, when known.
    public let commit: OID?
    /// What it is about: the merge message's first line, or the commit's summary.
    public let summary: String
    /// For a rebase, which commit (from 1) of how many is being replayed.
    public let step: Int?
    public let total: Int?
    /// How many more commits wait to be applied after this one.
    public let queued: Int
    public let conflictedPaths: [String]

    /// Whether the current commit can be left out and the rest applied. A
    /// merge is one step, so it can only be finished or aborted.
    public var canSkip: Bool { kind != .merge }
    public var hasConflicts: Bool { !conflictedPaths.isEmpty }
}

extension Repository {
    // MARK: Merge

    /// Merges a branch, remote branch or tag, by its full reference name,
    /// into `HEAD`; or any other revision, such as a commit's hash, which
    /// git names "commit 'x'" in the message. `message` replaces the usual
    /// "Merge branch 'x'".
    @discardableResult
    public func merge(_ reference: String, mode: MergeMode, message: String? = nil) throws -> MergeOutcome {
        try merge(reference, mode: mode, message: message, fastForwardLog: nil)
    }

    /// The merge, with the reflog message a fast-forward records: a pull
    /// writes its own, as git's does.
    func merge(_ reference: String, mode: MergeMode, message: String?, fastForwardLog: String?) throws -> MergeOutcome {
        try requireNoOperation()
        let theirs = try annotatedCommit(for: reference)
        defer { git_annotated_commit_free(theirs) }
        let theirID = OID(git_annotated_commit_id(theirs))

        var heads: [OpaquePointer?] = [theirs]
        var analysis = git_merge_analysis_t(0)
        var preference = git_merge_preference_t(0)
        try check(git_merge_analysis(&analysis, &preference, pointer, &heads, 1))
        func has(_ flag: git_merge_analysis_t) -> Bool { analysis.rawValue & flag.rawValue != 0 }

        if has(GIT_MERGE_ANALYSIS_UP_TO_DATE) {
            return .upToDate
        }
        if has(GIT_MERGE_ANALYSIS_UNBORN) || (has(GIT_MERGE_ANALYSIS_FASTFORWARD) && mode == .fastForwardWhenPossible) {
            let commit = try lookupCommit(theirID)
            defer { git_commit_free(commit) }
            try checkOutTree(of: commit)
            try moveHeadTarget(to: theirID, log: fastForwardLog ?? "merge \(shortName(of: reference)): Fast-forward")
            return .fastForwarded(to: theirID)
        }

        // A merge commit needs an identity: find out before touching anything.
        let signature = try branchingSignature()
        defer { git_signature_free(signature) }
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? defaultMergeMessage(for: reference, squash: mode == .squash)

        var mergeOptions = git_merge_options()
        try check(git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        var checkoutOptions = git_checkout_options()
        try check(git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try check(git_merge(pointer, &heads, 1, &mergeOptions, &checkoutOptions))

        if mode == .squash {
            // A squash is not a merge: nothing records the other branch.
            try check(git_repository_state_cleanup(pointer))
        } else {
            // libgit2 writes the bare message; keep the caller's instead, for
            // whoever concludes the merge after resolving conflicts.
            try writeGitFile("MERGE_MSG", text + "\n")
        }
        let conflicts = try conflictedPaths()
        if !conflicts.isEmpty {
            return .conflicts(conflicts)
        }
        let parents = mode == .squash ? [] : [theirID]
        let id = try commitIndex(message: text, author: signature, committer: signature, extraParents: parents)
        try check(git_repository_state_cleanup(pointer))
        return .committed(id)
    }

    // MARK: Cherry-pick and revert

    /// Applies the changes of each commit on top of `HEAD`, in the order
    /// given, committing each with its original author and message. A commit
    /// whose changes are already there is passed over. Stops at the first
    /// conflict, to resume with `continueOperation()`.
    @discardableResult
    public func cherryPick(_ ids: [OID]) throws -> OperationOutcome {
        try startSequence(ids.map { SequenceItem(kind: .pick, id: $0) })
    }

    /// Undoes the changes of each commit on top of `HEAD`, in the order given
    /// (newest first undoes a run of commits cleanly), one commit each. A
    /// merge commit is undone against its first parent.
    @discardableResult
    public func revert(_ ids: [OID]) throws -> OperationOutcome {
        try startSequence(ids.map { SequenceItem(kind: .revert, id: $0) })
    }

    // MARK: Operations in progress

    /// The merge, rebase, cherry-pick or revert that has stopped, if any.
    public func ongoingOperation() throws -> OngoingOperation? {
        let conflicts = try conflictedPaths()
        switch RepositoryState(git_repository_state(pointer)) {
        case .merging:
            let message = repositoryMessage() ?? ""
            return OngoingOperation(
                kind: .merge, commit: try mergeHeadIDs().first,
                summary: message.split(separator: "\n").first.map(String.init) ?? "Merge",
                step: nil, total: nil, queued: 0, conflictedPaths: conflicts
            )
        case .cherryPicking, .reverting:
            let current = currentSequenceCommit()
            let todo = sequencerTodo()
            let queued = todo.first?.id == current?.id ? todo.count - 1 : todo.count
            return OngoingOperation(
                kind: current?.kind == .revert ? .revert : .cherryPick, commit: current?.id,
                summary: current.flatMap { try? commit($0.id).summary } ?? "",
                step: nil, total: nil, queued: max(queued, 0), conflictedPaths: conflicts
            )
        case .rebasing:
            return try rebaseProgress(conflicts: conflicts)
        default:
            return nil
        }
    }

    /// Finishes the step that stopped, once its conflicts are resolved, and
    /// carries on with whatever is left.
    @discardableResult
    public func continueOperation() throws -> OperationOutcome {
        switch RepositoryState(git_repository_state(pointer)) {
        case .merging:
            guard try conflictedPaths().isEmpty else { throw BranchingError.unresolvedConflicts }
            let signature = try branchingSignature()
            defer { git_signature_free(signature) }
            let message = repositoryMessage()?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Merge"
            _ = try commitIndex(
                message: message, author: signature, committer: signature, extraParents: try mergeHeadIDs()
            )
            try check(git_repository_state_cleanup(pointer))
            return .finished
        case .cherryPicking, .reverting:
            guard try conflictedPaths().isEmpty else { throw BranchingError.unresolvedConflicts }
            let signature = try branchingSignature()
            git_signature_free(signature)
            let (current, rest, sequence) = takeSequence()
            if let current {
                try commitSequenceItem(current)
            }
            try check(git_repository_state_cleanup(pointer))
            return try runSequence(rest, sequence: sequence)
        case .rebasing:
            return try continueRebase()
        default:
            throw BranchingError.nothingInProgress
        }
    }

    /// Leaves out the commit that stopped a rebase, cherry-pick or revert,
    /// discarding its changes, and carries on with the rest.
    @discardableResult
    public func skipOperation() throws -> OperationOutcome {
        switch RepositoryState(git_repository_state(pointer)) {
        case .cherryPicking, .reverting:
            let (_, rest, sequence) = takeSequence()
            try restoreTouchedPathsToHead()
            try check(git_repository_state_cleanup(pointer))
            return try runSequence(rest, sequence: sequence)
        case .rebasing:
            return try skipRebase()
        case .merging:
            throw BranchingError.operationInProgress(.merging)
        default:
            throw BranchingError.nothingInProgress
        }
    }

    /// Gives up the operation in progress and returns to where it started.
    /// Files it changed lose those changes, including conflict resolutions;
    /// other local changes are kept.
    public func abortOperation() throws {
        switch RepositoryState(git_repository_state(pointer)) {
        case .merging:
            try restoreTouchedPathsToHead()
            try check(git_repository_state_cleanup(pointer))
        case .cherryPicking, .reverting:
            let (_, _, sequence) = takeSequence()
            try restoreTouchedPathsToHead()
            try check(git_repository_state_cleanup(pointer))
            // Like git, undo the commits the sequence already made, unless
            // something else has moved HEAD since it stopped.
            if let sequence, let head = try head().target, head != sequence.originalHead,
               sequence.abortSafety == nil || sequence.abortSafety == head {
                let original = try lookupCommit(sequence.originalHead)
                defer { git_commit_free(original) }
                try checkOutTree(of: original)
                try moveHeadTarget(to: sequence.originalHead, log: "cherry-pick: abort")
            }
        case .rebasing:
            try abortRebase()
        default:
            throw BranchingError.nothingInProgress
        }
    }

    // MARK: Sequences

    private func startSequence(_ items: [SequenceItem]) throws -> OperationOutcome {
        try requireNoOperation()
        guard !items.isEmpty else { return .finished }
        let signature = try branchingSignature()
        git_signature_free(signature)
        guard let head = try head().target else {
            throw GitError(code: GIT_EUNBORNBRANCH.rawValue, message: "There is no commit to apply changes on yet.")
        }
        if try hasStagedChanges() {
            throw GitError(
                code: GIT_EUNCOMMITTED.rawValue,
                message: "There are staged changes. Commit or unstage them first."
            )
        }
        let sequence = items.count > 1 ? SequenceState(originalHead: head, abortSafety: nil) : nil
        return try runSequence(items, sequence: sequence)
    }

    /// Applies items in turn. `sequence` is set for runs of more than one
    /// commit, which keep git's sequencer files when they stop so that the
    /// command line git can resume them too.
    private func runSequence(_ items: [SequenceItem], sequence: SequenceState?) throws -> OperationOutcome {
        for (position, item) in items.enumerated() {
            try apply(item)
            let conflicts = try conflictedPaths()
            if !conflicts.isEmpty {
                if let sequence {
                    try writeSequencer(Array(items[position...]), originalHead: sequence.originalHead)
                }
                return .stopped(at: item.id, conflicts: conflicts)
            }
            try commitSequenceItem(item)
            try check(git_repository_state_cleanup(pointer))
        }
        return .finished
    }

    private func apply(_ item: SequenceItem) throws {
        let commit = try lookupCommit(item.id)
        defer { git_commit_free(commit) }
        let mainline = git_commit_parentcount(commit) > 1 ? UInt32(1) : 0
        switch item.kind {
        case .pick:
            var options = git_cherrypick_options()
            try check(git_cherrypick_options_init(&options, UInt32(GIT_CHERRYPICK_OPTIONS_VERSION)))
            options.mainline = mainline
            options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            try check(git_cherrypick(pointer, commit, &options))
        case .revert:
            var options = git_revert_options()
            try check(git_revert_options_init(&options, UInt32(GIT_REVERT_OPTIONS_VERSION)))
            options.mainline = mainline
            options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            try check(git_revert(pointer, commit, &options))
        }
    }

    /// Commits the index for a picked or reverted commit. A pick that changes
    /// nothing, because its changes are already there, makes no commit.
    private func commitSequenceItem(_ item: SequenceItem) throws {
        let original = try lookupCommit(item.id)
        defer { git_commit_free(original) }
        let committer = try branchingSignature()
        defer { git_signature_free(committer) }

        let head = try headCommit()
        defer { git_commit_free(head) }
        let index = try branchingIndex()
        defer { git_index_free(index) }
        var treeID = git_oid()
        try check(git_index_write_tree(&treeID, index))
        if let head, OID(git_commit_tree_id(head)) == OID(treeID) {
            return
        }

        switch item.kind {
        case .pick:
            let message = git_commit_message(original).map { String(cString: $0) } ?? ""
            _ = try commitIndex(
                message: message, author: git_commit_author(original), committer: committer, extraParents: [],
                keepsMessage: true
            )
        case .revert:
            let summary = git_commit_summary(original).map { String(cString: $0) } ?? ""
            var message = "Revert \"\(summary)\"\n\nThis reverts commit \(item.id.hex)"
            if git_commit_parentcount(original) > 1 {
                message += ", reversing\nchanges made to \(OID(git_commit_parent_id(original, 0)).hex)"
            }
            _ = try commitIndex(message: message + ".", author: committer, committer: committer, extraParents: [])
        }
    }

    /// The commit a stopped cherry-pick or revert is applying.
    private func currentSequenceCommit() -> SequenceItem? {
        if let id = readGitFile("CHERRY_PICK_HEAD").flatMap(OID.init(hex:)) {
            return SequenceItem(kind: .pick, id: id)
        }
        if let id = readGitFile("REVERT_HEAD").flatMap(OID.init(hex:)) {
            return SequenceItem(kind: .revert, id: id)
        }
        return nil
    }

    /// Reads the stopped item, the items after it and the sequence they
    /// belong to.
    private func takeSequence() -> (current: SequenceItem?, rest: [SequenceItem], sequence: SequenceState?) {
        let current = currentSequenceCommit()
        var todo = sequencerTodo()
        if let current, todo.first?.id == current.id {
            todo.removeFirst()
        }
        let sequence = readGitFile("sequencer/head").flatMap(OID.init(hex:)).map {
            SequenceState(originalHead: $0, abortSafety: readGitFile("sequencer/abort-safety").flatMap(OID.init(hex:)))
        }
        return (current, todo, sequence)
    }

    /// The commits in git's `sequencer/todo`, the stopped one first.
    private func sequencerTodo() -> [SequenceItem] {
        guard let text = readGitFile("sequencer/todo") else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ", maxSplits: 2)
            guard words.count >= 2 else { return nil }
            let kind: SequenceItem.Kind
            switch words[0] {
            case "pick", "p": kind = .pick
            case "revert": kind = .revert
            default: return nil
            }
            guard let id = resolveCommit(String(words[1])) else { return nil }
            return SequenceItem(kind: kind, id: id)
        }
    }

    /// Writes git's sequencer files: what is left (the stopped commit first),
    /// where the sequence started, and where `HEAD` was when it stopped.
    private func writeSequencer(_ items: [SequenceItem], originalHead: OID) throws {
        let directory = gitDirectory.appending(path: "sequencer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let todo = items.map { item in
            let summary = (try? commit(item.id).summary) ?? ""
            return "\(item.kind == .pick ? "pick" : "revert") \(item.id.hex) \(summary)\n"
        }.joined()
        try writeGitFile("sequencer/todo", todo)
        try writeGitFile("sequencer/head", originalHead.hex + "\n")
        if let head = try head().target {
            try writeGitFile("sequencer/abort-safety", head.hex + "\n")
        }
    }

    private func resolveCommit(_ name: String) -> OID? {
        var object: OpaquePointer?
        guard git_revparse_single(&object, pointer, name) == 0 else { return nil }
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        guard git_object_peel(&commit, object, GIT_OBJECT_COMMIT) == 0 else { return nil }
        defer { git_object_free(commit) }
        return OID(git_object_id(commit))
    }

    // MARK: Shared with rebasing

    func requireNoOperation() throws {
        let state = RepositoryState(git_repository_state(pointer))
        guard state == .clean else { throw BranchingError.operationInProgress(state) }
    }

    /// The paths with conflicts in the index.
    func conflictedPaths() throws -> [String] {
        let index = try branchingIndex()
        defer { git_index_free(index) }
        guard git_index_has_conflicts(index) != 0 else { return [] }
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index))
        defer { git_index_conflict_iterator_free(iterator) }
        var ancestor: UnsafePointer<git_index_entry>?
        var ours: UnsafePointer<git_index_entry>?
        var theirs: UnsafePointer<git_index_entry>?
        var paths: [String] = []
        while git_index_conflict_next(&ancestor, &ours, &theirs, iterator) == 0 {
            if let entry = ours ?? theirs ?? ancestor {
                paths.append(String(cString: entry.pointee.path))
            }
        }
        return paths
    }

    /// Returns every path the stopped operation touched, in the index or in
    /// conflict, to its state in `HEAD`, in both the index and the working
    /// tree. Changes to other files are kept.
    func restoreTouchedPathsToHead() throws {
        guard let head = try headCommit() else { return }
        defer { git_commit_free(head) }
        let headTree = try tree(of: head)
        defer { git_tree_free(headTree) }

        var paths = Set(try conflictedPaths())
        let index = try branchingIndex()
        defer { git_index_free(index) }
        var diff: OpaquePointer?
        try check(git_diff_tree_to_index(&diff, pointer, headTree, index, nil))
        defer { git_diff_free(diff) }
        for position in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, position)?.pointee else { continue }
            if let path = delta.old_file.path { paths.insert(String(cString: path)) }
            if let path = delta.new_file.path { paths.insert(String(cString: path)) }
        }
        guard !paths.isEmpty else { return }

        try withStringArray(Array(paths).sorted()) { array in
            // First the index, which also drops the conflict entries…
            try check(git_reset_default(pointer, head, &array))
            // …then the files: restored, or removed where HEAD has none.
            var options = git_checkout_options()
            try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
            options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_REMOVE_UNTRACKED.rawValue
                | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
            options.paths = array
            try check(git_checkout_tree(pointer, headTree, &options))
        }
    }

    /// Commits the index on top of `HEAD` and any `extraParents`.
    func commitIndex(
        message: String,
        author: UnsafePointer<git_signature>,
        committer: UnsafePointer<git_signature>,
        extraParents: [OID],
        keepsMessage: Bool = false
    ) throws -> OID {
        let index = try branchingIndex()
        defer { git_index_free(index) }
        var treeID = git_oid()
        try check(git_index_write_tree(&treeID, index))
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &treeID))
        defer { git_tree_free(tree) }

        var parents: [OpaquePointer?] = []
        defer { parents.forEach { git_commit_free($0) } }
        if let head = try headCommit() {
            parents.append(head)
        }
        for id in extraParents {
            parents.append(try lookupCommit(id))
        }
        // A picked commit's message is kept byte for byte, as git keeps it.
        let text = keepsMessage ? message : message.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        var id = git_oid()
        try check(git_commit_create(
            &id, pointer, "HEAD", author, committer, nil, text, tree, parents.count, &parents
        ))
        return OID(id)
    }

    /// Points the current branch, or a detached `HEAD`, at a commit. The
    /// working tree is the caller's business.
    func moveHeadTarget(to id: OID, log: String) throws {
        var oid = id.raw
        switch try head() {
        case .detached:
            try check(git_repository_set_head_detached(pointer, &oid))
        case .branch(let name, _), .unborn(let name):
            var reference: OpaquePointer?
            try check(git_reference_create(&reference, pointer, name, &oid, 1, log))
            git_reference_free(reference)
        }
    }

    /// The repository's index, read again from disk. The caller frees it.
    func branchingIndex() throws -> OpaquePointer? {
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        // Pick up changes another git made since this repository was opened.
        try check(git_index_read(index, 0))
        return index
    }

    /// The `.git` folder.
    var gitDirectory: URL {
        URL(filePath: String(cString: git_repository_path(pointer)), directoryHint: .isDirectory)
    }

    func readGitFile(_ path: String) -> String? {
        (try? String(contentsOf: gitDirectory.appending(path: path), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func writeGitFile(_ path: String, _ text: String) throws {
        try text.write(to: gitDirectory.appending(path: path), atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    private func hasStagedChanges() throws -> Bool {
        let head = try headCommit()
        defer { git_commit_free(head) }
        let headTree = try tree(of: head)
        defer { git_tree_free(headTree) }
        let index = try branchingIndex()
        defer { git_index_free(index) }
        var diff: OpaquePointer?
        try check(git_diff_tree_to_index(&diff, pointer, headTree, index, nil))
        defer { git_diff_free(diff) }
        return git_diff_num_deltas(diff) > 0 || git_index_has_conflicts(index) != 0
    }

    /// The message a merge, cherry-pick or revert prepared, from `MERGE_MSG`.
    private func repositoryMessage() -> String? {
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        guard git_repository_message(&buffer, pointer) == 0, let text = buffer.ptr else { return nil }
        return String(cString: text)
    }

    private func mergeHeadIDs() throws -> [OID] {
        let collected = OIDCollector()
        let code = git_repository_mergehead_foreach(pointer, { id, payload in
            guard let id, let payload else { return 0 }
            Unmanaged<OIDCollector>.fromOpaque(payload).takeUnretainedValue().ids.append(OID(id))
            return 0
        }, Unmanaged.passUnretained(collected).toOpaque())
        if code == GIT_ENOTFOUND.rawValue { return [] }
        try check(code)
        return collected.ids
    }

    /// The message git writes for merging a reference.
    private func defaultMergeMessage(for reference: String, squash: Bool) -> String {
        let name = shortName(of: reference)
        let what = if !reference.hasPrefix("refs/") {
            "commit '\(reference)'"
        } else if reference.hasPrefix("refs/remotes/") {
            "remote-tracking branch '\(name)'"
        } else if reference.hasPrefix("refs/tags/") {
            "tag '\(name)'"
        } else {
            "branch '\(name)'"
        }
        if squash {
            return "Squashed commit of \(what)"
        }
        // git leaves out "into main" for the usual main branch names.
        if let current = (try? head())?.branchName.map(shortName(of:)), !["main", "master"].contains(current) {
            return "Merge \(what) into \(current)"
        }
        return "Merge \(what)"
    }

    /// What merging and rebasing start from: a full reference name, looked
    /// up as a reference so its name is kept, or any other revision. The
    /// caller frees it.
    func annotatedCommit(for revision: String) throws -> OpaquePointer? {
        var annotated: OpaquePointer?
        if revision.hasPrefix("refs/") {
            var reference: OpaquePointer?
            try check(git_reference_lookup(&reference, pointer, revision))
            defer { git_reference_free(reference) }
            try check(git_annotated_commit_from_ref(&annotated, pointer, reference))
        } else {
            try check(git_annotated_commit_from_revspec(&annotated, pointer, revision))
        }
        return annotated
    }

    func shortName(of reference: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference
    }
}

private struct SequenceItem: Hashable {
    enum Kind: Hashable {
        case pick
        case revert
    }

    let kind: Kind
    let id: OID
}

/// Where a run of several commits started, so that aborting can return there.
private struct SequenceState {
    let originalHead: OID
    /// Where `HEAD` was when the run stopped. Aborting leaves `HEAD` alone if
    /// it has moved since.
    let abortSafety: OID?
}

/// Gathers object IDs from a C callback, which cannot capture Swift state.
private final class OIDCollector {
    var ids: [OID] = []
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
