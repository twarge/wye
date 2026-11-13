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
