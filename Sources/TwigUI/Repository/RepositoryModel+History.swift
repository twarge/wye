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
}
