import GitKit
import SwiftUI

/// The screens commit detail can open on top of itself.
enum CommitRoute: Hashable {
    /// A file as it is at a commit.
    case file(path: String, commit: OID)
    /// The commits that changed a file, from a commit back.
    case fileHistory(path: String, commit: OID)
    case blame(path: String, commit: OID)

    @MainActor @ViewBuilder
    func destination(_ model: RepositoryModel) -> some View {
        switch self {
        case .file(let path, let commit):
            FileContentView(model: model, path: path, commitID: commit)
        case .fileHistory(let path, let commit):
            FileHistoryView(model: model, path: path, commitID: commit)
        case .blame(let path, let commit):
            BlameView(model: model, path: path, commitID: commit)
        }
    }
}

extension EnvironmentValues {
    /// Opens a screen on top of commit detail. Set by commit detail for
    /// everything shown inside it, including the screens it opens.
    @Entry var openCommitRoute = OpenCommitRouteAction { _ in }
}

/// Opens a screen on top of commit detail; call it like a function.
struct OpenCommitRouteAction {
    let handler: @MainActor (CommitRoute) -> Void

    @MainActor
    func callAsFunction(_ route: CommitRoute) {
        handler(route)
    }
}

/// What can be done with one file of a commit, offered from the header of
/// its diff.
struct FileActions {
    struct Item: Hashable {
        var title: String
        var systemImage: String
        var route: CommitRoute
    }

    var items: [Item]
    var open: OpenCommitRouteAction

    /// The actions for a file a commit changed. A deleted file has no
    /// contents to view or blame there, only a history.
    init(for file: FileDiff, in commitID: OID, open: OpenCommitRouteAction) {
        self.open = open
        if file.change == .deleted {
            items = [Item(title: "Show History", systemImage: "clock.arrow.circlepath",
                          route: .fileHistory(path: file.path, commit: commitID))]
        } else {
            items = [
                Item(title: "Show File", systemImage: "doc.text", route: .file(path: file.path, commit: commitID)),
                Item(title: "Show History", systemImage: "clock.arrow.circlepath",
                     route: .fileHistory(path: file.path, commit: commitID))
            ]
            if !file.isBinary {
                items.append(Item(title: "Blame", systemImage: "person.text.rectangle",
                                  route: .blame(path: file.path, commit: commitID)))
            }
        }
    }
}

extension View {
    /// Offers a file's actions as a context menu, when there are any.
    func fileActionsMenu(_ actions: FileActions?) -> some View {
        contextMenu {
            if let actions {
                ForEach(actions.items, id: \.self) { item in
                    Button(item.title, systemImage: item.systemImage) { actions.open(item.route) }
                }
            }
        }
    }
}
