import Foundation
import GitKit

extension RepositoryModel {
    // MARK: Names

    /// The checked-out branch's short name, or `nil` when `HEAD` is detached.
    var headBranchName: String? {
        snapshot?.head.branchName.map(Self.displayName(ofReference:))
    }

    /// What `HEAD` is, as a sentence names it: a branch, or a detached commit.
    var headDescription: String {
        switch snapshot?.head {
        case .branch(let name, _), .unborn(let name): "“\(Self.displayName(ofReference: name))”"
        case .detached(let id): "the detached HEAD (\(id.abbreviated()))"
        case nil: "HEAD"
        }
    }

    /// A reference's name without its `refs/heads/`, `refs/remotes/` or
    /// `refs/tags/`.
    static func displayName(ofReference name: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    func present(_ sheet: BranchingSheet) {
        branchingSheet = sheet
    }

    // MARK: Checking out

    func checkOutBranch(_ id: String) async {
        await perform(.checkout) { _ in try await self.withAutostash("Check Out") { try $0.checkOut(branch: id) } }
    }

    func checkOutTag(_ id: String) async {
        await perform(.checkout) { try await $0.checkOut(tag: id) }
    }

    func checkOutCommit(_ id: OID) async {
        await perform(.checkout) { try await $0.checkOut(commit: id) }
    }

    /// Checks out a remote branch as a local branch that tracks it, creating
    /// that branch unless one already tracks it.
    func trackRemoteBranch(_ id: String) async {
        await perform(.checkout) { repository in
            let local = try await repository.createTrackingBranch(for: id)
            try await self.withAutostash("Check Out") { try $0.checkOut(branch: local) }
            self.selection = .branch(local)
        }
    }

    // MARK: Branches and tags

    func renameBranch(_ id: String, to name: String) async {
        await perform(.renameBranch) { repository in
            let renamed = try await repository.renameBranch(id, to: name)
            self.interface.renamed(id, to: renamed)
            if self.selection == .branch(id) {
                self.selection = .branch(renamed)
            }
        }
    }

    /// Deletes a local branch and the remote branch it tracks. The remote
    /// branch goes first: if that fails, nothing has changed.
    func deleteBranch(_ id: String, force: Bool, alsoDeleting remoteBranch: String) async {
        guard await deleteRemoteBranch(remoteBranch) else { return }
        await deleteBranch(id, force: force)
    }

    /// Deletes a local branch that a linked worktree has checked out: the
    /// remote branch it tracks first, when that goes too, then the
    /// worktree, then the branch. Each goes only if the one before it did.
    func deleteBranch(
        _ id: String, force: Bool, alsoDeleting remoteBranch: String?,
        removingWorktree worktree: String, library: RepositoryLibrary
    ) async {
        if let remoteBranch {
            guard await deleteRemoteBranch(remoteBranch) else { return }
        }
        // The user saw what the worktree holds before choosing to remove it,
        // as Remove Worktree shows it.
        guard await removeWorktree(worktree, force: true, library: library) else { return }
        await deleteBranch(id, force: force)
    }

    func deleteBranch(_ id: String, force: Bool) async {
        await perform(.deleteBranch) { repository in
            try await repository.deleteBranch(id, force: force)
            self.interface.forget(id)
            if self.selection == .branch(id) {
                self.selection = .history
            }
        }
    }

    func setUpstream(of id: String, to upstream: String?) async {
        await perform(.setUpstream) { try await $0.setUpstream(of: id, to: upstream) }
    }

    func createTag(named name: String, at commit: OID, message: String?) async {
        await perform(.createTag) { _ = try await $0.createTag(named: name, at: commit, message: message) }
    }

    func deleteTag(_ id: String) async {
        await perform(.deleteTag) { repository in
            try await repository.deleteTag(id)
            if self.selection == .tag(id) {
                self.selection = .history
            }
        }
    }

    func resetCurrentBranch(to commit: OID, mode: ResetMode) async {
        await perform(.reset(mode)) { try await $0.reset(to: commit, mode: mode) }
    }

    // MARK: Merging and rewriting

    func mergeIntoCurrent(_ reference: String, mode: MergeMode, message: String?) async {
        await perform(.merge) { repository in
            let outcome = try await self.withAutostash("Merge") { try $0.merge(reference, mode: mode, message: message) }
            if case .conflicts = outcome {
                self.showConflicts()
            }
        }
    }

    func rebaseCurrent(onto reference: String) async {
        await runSequence(.rebase) { _ in try await self.withAutostash("Rebase") { try $0.rebase(onto: reference) } }
    }

    /// Applies commits on top of `HEAD`. They come newest first, as the
    /// history lists them, and are applied oldest first, as they were made.
    func cherryPick(_ ids: [OID]) async {
        await runSequence(.cherryPick(count: ids.count)) { try await $0.cherryPick(ids.reversed()) }
    }

    /// Undoes commits, given newest first as the history lists them, in that
    /// order, so each undo applies to what came after it.
    func revert(_ ids: [OID]) async {
        await runSequence(.revert(count: ids.count)) { try await $0.revert(ids) }
    }

    // MARK: An operation in progress

    func continueOperation() async {
        await recordingResumedRebase { await runSequence { try await $0.continueOperation() } }
    }

    func skipOperation() async {
        await recordingResumedRebase { await runSequence { try await $0.skipOperation() } }
    }

    func abortOperation() async {
        await perform { try await $0.abortOperation() }
    }

    /// Runs something that can stop on a conflict, and shows the conflicts if
    /// it does.
    private func runSequence(
        _ undoable: UndoOperation? = nil, _ operation: @escaping (Repository) async throws -> OperationOutcome
    ) async {
        let body: (Repository) async throws -> Void = { repository in
            if case .stopped = try await operation(repository) {
                self.showConflicts()
            }
        }
        if let undoable {
            await perform(undoable, body)
        } else {
            await perform(body)
        }
    }

    /// The working copy is where conflicts are resolved.
    private func showConflicts() {
        selection = .workingCopy
    }
}
