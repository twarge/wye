import GitKit
import SwiftUI

/// Makes a local branch that tracks a remote branch, under a name of the
/// user's choosing, and checks it out if asked.
struct TrackRemoteBranchSheet: View {
    var model: RepositoryModel
    /// The remote branch, by full name.
    var remoteBranch: String

    @State private var name: String
    @State private var checksOut = true

    init(model: RepositoryModel, remoteBranch: String) {
        self.model = model
        self.remoteBranch = remoteBranch
        _name = State(initialValue: model.remoteParts(of: remoteBranch).branch)
    }

    var body: some View {
        BranchingSheetForm(title: "Track Remote Branch", confirmTitle: "Create", canConfirm: canCreate, confirm: create) {
            Section {
                LabeledContent("Remote Branch", value: RepositoryModel.displayName(ofReference: remoteBranch))
                TextField("Local Name", text: $name)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                Toggle("Check Out", isOn: $checksOut)
            } footer: {
                Text(footer)
            }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var exists: Bool {
        model.snapshot?.branches.contains { $0.name == trimmed } == true
    }

    private var canCreate: Bool { !trimmed.isEmpty && !exists }

    private var footer: String {
        if exists {
            return "A branch named “\(trimmed)” already exists."
        }
        return "The new branch starts at the remote branch’s commit, and pulls and pushes go to it."
    }

    private func create() {
        let (remoteBranch, name, checksOut) = (remoteBranch, trimmed, checksOut)
        Task { await model.trackRemoteBranch(remoteBranch, named: name, checkOut: checksOut) }
    }
}
