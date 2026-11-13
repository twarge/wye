import Foundation
import GitKit

extension RepositoryModel {
    /// Shows a commit in the history, leaving whatever else the sidebar had
    /// selected when it lists no history.
    func showInHistory(_ id: OID) {
        if selection?.historyScope == nil {
            selection = .history
        }
        history.selection = id
    }

    /// Shows a commit in the full history, out of a search or the reflog:
    /// ends the search, reads on until the commit is listed, selects it and
    /// scrolls to it.
    func revealInHistory(_ id: OID) async {
        if selection?.historyScope == nil {
            selection = .history
        }
        if let scope = selection?.historyScope {
            await history.show(scope)
        }
        if await !history.reveal(id), !Task.isCancelled {
            report(NotInHistory())
        }
    }

    /// The commit the branch or tag just selected in the sidebar points at,
    /// once the snapshot lists it: one selected inside an operation is
    /// listed only by the refresh after it.
    var commitToReveal: OID? {
        switch referenceToReveal {
        case .branch(let id):
            snapshot?.branches.first { $0.id == id }?.target
        case .remoteBranch(let id):
            snapshot?.remotes.lazy.flatMap(\.branches).first { $0.id == id }?.target
        case .tag(let id):
            snapshot?.tags.first { $0.id == id }?.target
        default:
            nil
        }
    }

    /// Selects the commit the branch or tag just selected in the sidebar
    /// points at in the full history, and scrolls to it.
    func revealSelectedReference() async {
        guard let reference = referenceToReveal, let target = commitToReveal else { return }
        await history.select(target)
        // Arrowing on through the sidebar has selected another one.
        guard !Task.isCancelled, referenceToReveal == reference else { return }
        referenceToReveal = nil
    }

    // MARK: Reopening

    /// Shows what a window showed when it closed: the sidebar's selection,
    /// and the commit selected in the history once that is on screen.
    func restore(_ saved: SavedWindow) {
        guard saved.repository == id else { return }
        if let selection = saved.selection {
            self.selection = selection
            restoredSelection = selection
        }
        if let commit = saved.commitID {
            commitToRestore = commit
            // The saved commit, not the one the branch or tag points at.
            referenceToReveal = nil
        }
    }

    /// Selects the commit a reopened window had selected, once the history
    /// is on screen, and only once.
    func restoreSelectedCommit() async {
        guard let commit = commitToRestore, selection?.historyScope != nil, referenceToReveal == nil else { return }
        commitToRestore = nil
        // Quietly, if no branch or tag leads to it any more.
        _ = await history.select(commit)
    }

    /// Goes to the full history in place of a restored branch, tag, remote
    /// branch, submodule, worktree or pull request list that is gone,
    /// once the first snapshot says.
    func checkRestoredSelection() {
        guard let item = restoredSelection, let snapshot else { return }
        restoredSelection = nil
        guard selection == item else { return }
        let isThere = switch item {
        case .branch(let id): snapshot.branches.contains { $0.id == id }
        case .remoteBranch(let id): snapshot.remotes.contains { $0.branches.contains { $0.id == id } }
        case .tag(let id): snapshot.tags.contains { $0.id == id }
        case .submodule(let name): submodule(named: name) != nil
        case .worktree(let name): worktree(named: name) != nil
        case .pullRequests: pullRequestTarget != nil
        case .workingCopy, .history, .stashes, .reflog: true
        }
        if !isThere { selection = .history }
    }

    /// Selects the commit `HEAD` points at: in the history on screen when it
    /// is the full history or the checked-out branch's, otherwise in the
    /// full history.
    func showHead() async {
        guard let target = snapshot?.head.target else { return }
        let headBranch = snapshot?.head.branchName
        switch selection {
        case .history:
            break
        case .branch(let id) where id == headBranch:
            break
        default:
            selection = .history
        }
        await revealInHistory(target)
    }
}

private struct NotInHistory: LocalizedError {
    var errorDescription: String? {
        "That commit is not in this history: no branch, tag or HEAD leads to it any more."
    }
}
