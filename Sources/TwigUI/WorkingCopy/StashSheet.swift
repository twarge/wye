import GitKit
import SwiftUI

/// Sets the working copy's changes aside in a new stash.
struct StashSheet: View {
    var model: RepositoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = false
    @State private var keepIndex = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Message", text: $message, prompt: Text("Optional"))
                } footer: {
                    Text("Without a message, the stash is named after the branch and its last commit.")
                }
                Section {
                    Toggle("Include untracked files", isOn: $includeUntracked)
                    Toggle("Keep staged changes", isOn: $keepIndex)
                } footer: {
                    Text("Keeping staged changes stashes them too, but also leaves them in place.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Stash Changes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Stash") {
                        var options: StashOptions = []
                        if includeUntracked { options.insert(.includeUntracked) }
                        if keepIndex { options.insert(.keepIndex) }
                        Task {
                            await model.saveStash(message: message, options: options)
                            dismiss()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 380)
    }
}
