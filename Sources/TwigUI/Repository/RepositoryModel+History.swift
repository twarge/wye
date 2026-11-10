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
        if await !history.reveal(id) {
            error = PresentedError(NotInHistory())
        }
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
