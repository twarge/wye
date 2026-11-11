import GitKit
import SwiftUI

/// The menu of a stash, top to bottom: put its changes back, make a branch
/// of it, write it out or copy its message, and drop it.
struct StashMenu: View {
    var model: RepositoryModel
    var stash: Stash
    /// Asks to confirm dropping it.
    var drop: () -> Void

    var body: some View {
        Section {
            StashApplyButton(model: model, stash: stash)
            StashPopButton(model: model, stash: stash)
        }
        Section {
            Button("New Branch from Stash…", systemImage: "arrow.triangle.branch") {
                model.present(.branchFromStash(stash))
            }
            .disabled(model.isBusy)
            .help("Make a branch where the stash was made, with its changes applied")
        }
        Section {
            Button("Save as Patch…", systemImage: "square.and.arrow.down") {
                Task { await model.exportPatch(of: stash) }
            }
            .help("Save the changes to tracked files as a patch file")
            Button("Copy Message", systemImage: "doc.on.doc") {
                Platform.copyToClipboard(stash.title)
            }
        }
        Section {
            Button("Drop…", systemImage: "trash", role: .destructive, action: drop)
                .help("Delete the stash")
        }
    }
}

struct StashApplyButton: View {
    var model: RepositoryModel
    var stash: Stash

    var body: some View {
        Button("Apply", systemImage: "arrow.uturn.down") {
            Task { await model.apply(stash) }
        }
        .help("Apply the stash’s changes and keep the stash")
    }
}

struct StashPopButton: View {
    var model: RepositoryModel
    var stash: Stash

    var body: some View {
        Button("Pop", systemImage: "tray.and.arrow.up") {
            Task { await model.pop(stash) }
        }
        .help("Apply the stash’s changes, then drop it")
    }
}
