import GitKit
import SwiftUI

/// Saves the local changes in a snapshot: a stash that leaves them in place.
struct SnapshotSheet: View {
    var model: RepositoryModel

    @State private var message = ""

    var body: some View {
        BranchingSheetForm(
            title: "Create Snapshot", confirmTitle: "Create",
            canConfirm: !model.workingCopy.entries.isEmpty, confirm: save
        ) {
            Section {
                TextField("Name", text: $message, prompt: Text("Optional"))
            } footer: {
                Text("Saves every local change, untracked files too, as a stash and leaves the files as they are, "
                     + "staged changes staged. Apply the snapshot from Stashes to get this state back. "
                     + "Without a name, it is named with the date and time.")
            }
        }
    }

    private func save() {
        let message = message
        Task { await model.saveSnapshot(message: message) }
    }
}

/// Makes a branch from a stash: at the commit the stash was made on, with
/// its changes applied.
struct StashBranchSheet: View {
    var model: RepositoryModel
    var stash: Stash

    @State private var name = ""

    var body: some View {
        BranchingSheetForm(title: "New Branch from Stash", confirmTitle: "Create", canConfirm: canCreate, confirm: create) {
            Section {
                LabeledContent("Stash", value: stash.title)
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
            } footer: {
                Text(exists
                     ? "A branch named “\(trimmed)” already exists."
                     : "Makes the branch at the commit the stash was made on, checks it out and applies the stash "
                        + "there, staged changes staged. The stash is dropped once it applies; if it does not, it is kept.")
            }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var exists: Bool {
        model.snapshot?.branches.contains { $0.name == trimmed } == true
    }

    private var canCreate: Bool { !trimmed.isEmpty && !exists }

    private func create() {
        let (stash, name) = (stash, trimmed)
        Task { await model.createBranch(fromStash: stash, named: name) }
    }
}
