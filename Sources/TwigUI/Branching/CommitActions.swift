import GitKit
import SwiftUI

extension View {
    /// Adds the branching actions for a commit as the view's context menu.
    func commitActions(model: RepositoryModel, commit: Commit) -> some View {
        contextMenu {
            CommitActionsMenu(model: model, commit: commit)
        }
    }
}

/// The actions on a commit in a history: check it out, branch or tag it,
/// apply or undo its changes, reset to it, copy its name.
struct CommitActionsMenu: View {
    var model: RepositoryModel
    var commit: Commit

    var body: some View {
        Button("Check Out", systemImage: "arrow.uturn.down") {
            Task { await model.checkOutCommit(commit.id) }
        }
        .disabled(isHead)
        Button("New Branch Here…", systemImage: "arrow.triangle.branch") {
            model.present(.newBranch(at: commit.id))
        }
        Button("New Tag Here…", systemImage: "tag") {
            model.present(.newTag(at: commit.id))
        }

        Divider()

        Button("Cherry-Pick", systemImage: "arrow.down.to.line") {
            Task { await model.cherryPick([commit.id]) }
        }
        .disabled(isHead || isBusy)
        Button("Revert", systemImage: "arrow.uturn.backward") {
            Task { await model.revert([commit.id]) }
        }
        .disabled(isBusy)
        Button("Reset Current Branch to Here…", systemImage: "arrow.counterclockwise") {
            model.present(.reset(to: commit.id))
        }
        .disabled(isHead || model.snapshot?.head.target == nil)

        Divider()

        Button("Copy Hash", systemImage: "doc.on.doc") {
            Platform.copyToClipboard(commit.id.hex)
        }
    }

    private var isHead: Bool {
        model.snapshot?.head.target == commit.id
    }

    /// Whether another operation has to be finished first.
    private var isBusy: Bool {
        model.snapshot?.state ?? .clean != .clean
    }
}
