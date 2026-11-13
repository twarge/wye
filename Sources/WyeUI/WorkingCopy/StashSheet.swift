import GitKit
import SwiftUI

/// Sets the working copy's changes aside in a new stash: all of them, or
/// only those to some files.
struct StashSheet: View {
    var model: RepositoryModel
    /// The files to stash; `nil` for every change.
    var paths: [String]? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = false
    @State private var keepIndex = false

    var body: some View {
        SheetStack(title) {
            Form {
                SheetTitleSection()
                if let paths {
                    Section {
                        ForEach(paths.prefix(8), id: \.self) { path in
                            Text(path)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        if paths.count > 8 {
                            Text("and \((paths.count - 8).formatted()) more")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Only these files’ changes, staged and unstaged, go into the stash. The other changes stay.")
                    }
                }
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
            .groupedFormStyle()
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
                            if let paths {
                                await model.saveStash(paths: paths, message: message, options: options)
                            } else {
                                await model.saveStash(message: message, options: options)
                            }
                            dismiss()
                        }
                    }
                }
            }
        }
        .sheetMinimumSize(width: 380)
        .onAppear {
            // A chosen untracked file is meant to go into the stash.
            if let paths {
                let chosen = Set(paths)
                includeUntracked = model.workingCopy.entries.contains { chosen.contains($0.path) && $0.unstaged == .untracked }
            }
        }
    }

    private var title: String {
        guard let paths else { return "Stash Changes" }
        return paths.count == 1 ? "Stash “\(paths[0].splitPath.name)”" : "Stash \(paths.count.formatted()) Files"
    }
}
