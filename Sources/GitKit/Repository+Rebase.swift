import Clibgit2
import Foundation

extension Repository {
    /// Replays the current branch's own commits on top of another branch,
    /// given by its full reference name or any other revision, such as a
    /// commit's hash, through libgit2's rebase. Merge
    /// commits are left out and commits whose changes are already there are
    /// dropped, as git does. Stops at the first conflict, to resume with
    /// `continueOperation()` or `skipOperation()`, or undo with
    /// `abortOperation()`.
    @discardableResult
    public func rebase(onto reference: String) throws -> OperationOutcome {
        try requireNoOperation()
        let signature = try branchingSignature()
        git_signature_free(signature)

        let upstream = try annotatedCommit(for: reference)
        defer { git_annotated_commit_free(upstream) }

        var options = try rebaseOptions()
        var rebase: OpaquePointer?
        try check(git_rebase_init(&rebase, pointer, nil, upstream, nil, &options))
        defer { git_rebase_free(rebase) }
        return try runRebase(rebase)
    }

    /// Moves the commits of the current branch that `upstream` lacks onto
    /// `newBase`, as `git rebase --onto newBase upstream` does: merge
    /// commits are left out, commits whose changes are already there are
    /// dropped, and a conflict stops it as `rebase(onto:)` does. Each is a
    /// full reference name or any other revision.
    @discardableResult
    public func rebase(onto newBase: String, upstream: String) throws -> OperationOutcome {
        try requireNoOperation()
        let signature = try branchingSignature()
        git_signature_free(signature)

        let upstreamCommit = try annotatedCommit(for: upstream)
        defer { git_annotated_commit_free(upstreamCommit) }
        let ontoCommit = try annotatedCommit(for: newBase)
        defer { git_annotated_commit_free(ontoCommit) }

        var options = try rebaseOptions()
        var rebase: OpaquePointer?
        try check(git_rebase_init(&rebase, pointer, nil, upstreamCommit, ontoCommit, &options))
        defer { git_rebase_free(rebase) }
        return try runRebase(rebase)
    }

    func continueRebase() throws -> OperationOutcome {
        if isInteractiveSequencerActive { return try continueSequencer() }
        guard try conflictedPaths().isEmpty else { throw BranchingError.unresolvedConflicts }
        let rebase = try openRebase()
        defer { git_rebase_free(rebase) }
        if currentOperation(of: rebase) != nil {
            try commitRebaseStep(rebase)
        }
        return try runRebase(rebase)
    }

    func skipRebase() throws -> OperationOutcome {
        if isInteractiveSequencerActive { return try skipSequencer() }
        let rebase = try openRebase()
        defer { git_rebase_free(rebase) }
        try resetHardToHead()
        return try runRebase(rebase)
    }

    func abortRebase() throws {
        if isInteractiveSequencerActive { return try abortSequencer() }
        let rebase = try openRebase()
        defer { git_rebase_free(rebase) }
        // Returns the branch, index and working tree to where they were. A
        // rebase only starts from a clean working copy, so this loses no
        // more than the stopped step's resolutions.
        try check(git_rebase_abort(rebase))
    }

    func rebaseProgress(conflicts: [String]) throws -> OngoingOperation {
        if isInteractiveSequencerActive { return sequencerProgress(conflicts: conflicts) }
        var rebase: OpaquePointer?
        var options = try rebaseOptions()
        guard git_rebase_open(&rebase, pointer, &options) == 0 else {
            // A rebase libgit2 cannot read, such as one the command line
            // started with its own format: still show that one is under way.
            return OngoingOperation(
                kind: .rebase, commit: nil, summary: "", step: nil, total: nil, queued: 0, conflictedPaths: conflicts
            )
        }
        defer { git_rebase_free(rebase) }
        let total = git_rebase_operation_entrycount(rebase)
        let current = currentOperation(of: rebase)
        let id = current.flatMap { git_rebase_operation_byindex(rebase, $0) }.map { OID($0.pointee.id) }
        return OngoingOperation(
            kind: .rebase,
            commit: id,
            summary: id.flatMap { try? commit($0).summary } ?? "",
            step: current.map { $0 + 1 },
            total: total,
            queued: current.map { total - $0 - 1 } ?? total,
            conflictedPaths: conflicts
        )
    }

    // MARK: Steps

    /// Applies the remaining steps, committing each, until one conflicts or
    /// none are left, and then finishes.
    private func runRebase(_ rebase: OpaquePointer?) throws -> OperationOutcome {
        while true {
            var operation: UnsafeMutablePointer<git_rebase_operation>?
            let code = git_rebase_next(&operation, rebase)
            if code == GIT_ITEROVER.rawValue { break }
            try check(code)
            guard let operation else { continue }
            let conflicts = try conflictedPaths()
            if !conflicts.isEmpty {
                return .stopped(at: OID(operation.pointee.id), conflicts: conflicts)
            }
            try commitRebaseStep(rebase)
        }
        let signature = try branchingSignature()
        defer { git_signature_free(signature) }
        try check(git_rebase_finish(rebase, signature))
        return .finished
    }

    /// Commits the current step with its original author and message. A step
    /// whose changes are already upstream makes no commit.
    private func commitRebaseStep(_ rebase: OpaquePointer?) throws {
        let signature = try branchingSignature()
        defer { git_signature_free(signature) }
        var id = git_oid()
        let code = git_rebase_commit(&id, rebase, nil, signature, nil, nil)
        if code == GIT_EAPPLIED.rawValue { return }
        try check(code)
    }

    private func openRebase() throws -> OpaquePointer? {
        var options = try rebaseOptions()
        var rebase: OpaquePointer?
        try check(git_rebase_open(&rebase, pointer, &options))
        return rebase
    }

    /// The index of the step being applied, or `nil` before the first.
    private func currentOperation(of rebase: OpaquePointer?) -> Int? {
        let current = git_rebase_operation_current(rebase)
        // GIT_REBASE_NO_OPERATION is SIZE_MAX, which arrives as -1.
        return current >= 0 && current < git_rebase_operation_entrycount(rebase) ? current : nil
    }

    /// Puts the index and tracked files back as `HEAD` has them, as
    /// `git rebase --skip` does: a rebase only starts from a clean working
    /// copy, so this loses only the stopped step's changes. Untracked files stay.
    ///
    /// Not `git_reset`, which would also clear the rebase's own files.
    func resetHardToHead() throws {
        guard let head = try headCommit() else { return }
        defer { git_commit_free(head) }
        let tree = try tree(of: head)
        defer { git_tree_free(tree) }
        let index = try branchingIndex()
        defer { git_index_free(index) }

        // The paths the step added, which the files have to lose too.
        var added: [String] = []
        for position in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, position) else { continue }
            let path = String(cString: entry.pointee.path)
            var found: OpaquePointer?
            if git_tree_entry_bypath(&found, tree, path) == 0 {
                git_tree_entry_free(found)
            } else {
                added.append(path)
            }
        }
        try check(git_index_read_tree(index, tree))
        try check(git_index_write(index))
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        try check(git_checkout_tree(pointer, tree, &options))
        if let workdir = git_repository_workdir(pointer).map({ URL(filePath: String(cString: $0)) }) {
            for path in Set(added) {
                try? FileManager.default.removeItem(at: workdir.appending(path: path))
            }
        }
    }

    private func rebaseOptions() throws -> git_rebase_options {
        var options = git_rebase_options()
        try check(git_rebase_options_init(&options, UInt32(GIT_REBASE_OPTIONS_VERSION)))
        options.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        applyCommitSigning(to: &options)
        return options
    }
}
