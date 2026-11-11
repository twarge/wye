import GitKit
import SwiftUI

/// Changes an earlier commit's message or author. Every commit after it is
/// copied onto the new one, keeping its files, so the index and working copy
/// are left alone and nothing can conflict.
struct EditCommitSheet: View {
    var model: RepositoryModel
    var request: CommitEditRequest

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var name = ""
    @State private var email = ""
    @State private var date = Date()
    @State private var keepsDate = true
    @State private var isLoaded = false
    /// The remote branch that already has the commit, if any.
    @State private var publishedOn: String?
    /// How many commits after it are copied.
    @State private var later: Int?

    var body: some View {
        NavigationStack {
            Form {
                switch request.part {
                case .message:
                    Section {
                        TextEditor(text: $message)
                            .font(.body)
                            .frame(minHeight: 140)
                    }
                case .author:
                    Section {
                        TextField("Name", text: $name)
                        TextField("Email", text: $email)
                            .autocorrectionDisabled()
                            .noAutocapitalization()
                        Toggle("Keep the Original Date", isOn: $keepsDate)
                        if !keepsDate {
                            DatePicker("Date", selection: $date)
                        }
                    }
                }
                Section {
                } footer: {
                    Text(explanation)
                }
            }
            .formStyle(.grouped)
            .disabled(!isLoaded)
            .navigationTitle(request.part == .message ? "Edit Message" : "Edit Author")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .sheetMinimumSize(width: 460, height: 320)
        .task { await load() }
    }

    private var canSave: Bool {
        guard isLoaded, model.canStartMerge else { return false }
        switch request.part {
        case .message:
            return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .author:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@")
        }
    }

    private var explanation: String {
        var parts: [String] = []
        if let later, later > 0 {
            parts.append("The \(later) \(later == 1 ? "commit" : "commits") after it are copied onto the edited one, "
                         + "keeping their changes. Staged and unstaged changes stay as they are.")
        } else {
            parts.append("Only this commit changes. Staged and unstaged changes stay as they are.")
        }
        if let publishedOn {
            parts.append("This commit is already on \(publishedOn): editing it rewrites published history, and "
                         + "\(publishedOn) only takes the result with a force push.")
        }
        parts.append("Undo puts the branch back.")
        return parts.joined(separator: " ")
    }

    private func load() async {
        let repository = model.repository
        let commit = request.commit
        message = ([commit.summary, commit.body].filter { !$0.isEmpty }).joined(separator: "\n\n")
        name = commit.author.name
        email = commit.author.email
        date = commit.author.date
        publishedOn = try? await repository.remoteBranch(containing: commit.id)
        if let head = model.snapshot?.head.target {
            later = try? await repository.commitCount(from: commit.id, to: head)
        }
        isLoaded = true
    }

    private func save() {
        let commit = request.commit
        let newMessage = request.part == .message ? message : nil
        var author: Signature?
        if request.part == .author {
            let original = commit.author
            author = Signature(
                name: name.trimmingCharacters(in: .whitespaces),
                email: email.trimmingCharacters(in: .whitespaces),
                date: keepsDate ? original.date : date,
                timeZone: keepsDate ? original.timeZone : .current
            )
        }
        dismiss()
        Task { await model.editCommit(commit.id, message: newMessage, author: author) }
    }
}
