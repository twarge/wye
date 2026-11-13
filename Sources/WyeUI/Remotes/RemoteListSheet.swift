import GitKit
import SwiftUI

/// The repository's remotes, to add, change and remove.
struct RemoteListSheet: View {
    @Bindable var model: RepositoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var editing: RemoteEditor.Subject?
    @State private var removing: Remote?

    private var remotes: [Remote] { model.snapshot?.remotes ?? [] }

    var body: some View {
        SheetStack("Remotes", placement: .above(inset: 16)) {
            List {
                ForEach(remotes) { remote in
                    Button {
                        editing = .existing(remote)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(remote.name)
                                .font(.headline)
                            Text(remote.url ?? "No URL")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit…", systemImage: "pencil") { editing = .existing(remote) }
                        Button("Remove…", systemImage: "trash", role: .destructive) { removing = remote }
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { removing = remote }
                    }
                }
            }
            .overlay {
                if remotes.isEmpty {
                    ContentUnavailableView(
                        "No Remotes", systemImage: "server.rack",
                        description: Text("Add a remote to fetch from and push to.")
                    )
                }
            }
            #if os(macOS)
            // Under the list, as a Mac sheet has no bar for it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button("Add Remote…", systemImage: "plus") { editing = .new }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            #endif
            .toolbar {
                #if !os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Remote", systemImage: "plus") { editing = .new }
                }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { subject in
                RemoteEditor(model: model, subject: subject)
            }
            .confirmationDialog(
                "Remove “\(removing?.name ?? "")”?",
                isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
                titleVisibility: .visible,
                presenting: removing
            ) { remote in
                Button("Remove Remote", role: .destructive) {
                    Task { await model.removeRemote(remote) }
                }
            } message: { remote in
                Text(RemoveRemoteSheet.consequences(of: remote))
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        // The repository window's notices are behind this sheet.
        .sheetNotices(model)
    }
}

/// Adds a remote, or renames one and changes its URLs.
struct RemoteEditor: View {
    enum Subject: Identifiable {
        case new
        case existing(Remote)

        var id: String {
            switch self {
            case .new: ""
            case .existing(let remote): remote.name
            }
        }
    }

    var model: RepositoryModel
    var subject: Subject

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    /// Empty to push to the fetch URL.
    @State private var pushURL = ""

    var body: some View {
        SheetStack(isNew ? "New Remote" : "Edit Remote") {
            Form {
                SheetTitleSection()
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                TextField("URL", text: $url, prompt: Text("https://example.com/owner/project.git"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                Section {
                    TextField("Push URL", text: $pushURL, prompt: Text("Same as the URL"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                } footer: {
                    Text("Only when pushes go somewhere other than fetches, such as your own copy of the project.")
                }
            }
            .groupedFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { save() }
                        .disabled(trimmed(name).isEmpty || trimmed(url).isEmpty)
                }
            }
        }
        .frame(minWidth: 380)
        .task {
            if case .existing(let remote) = subject {
                pushURL = (try? await model.repository.pushURL(ofRemote: remote.name)) ?? ""
            }
        }
        .onAppear {
            if case .existing(let remote) = subject {
                name = remote.name
                url = remote.url ?? ""
            } else if model.snapshot?.remotes.isEmpty != false {
                name = "origin"
            }
        }
    }

    private var isNew: Bool {
        if case .new = subject { true } else { false }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let name = trimmed(name), url = trimmed(url), pushURL = trimmed(pushURL)
        let subject = subject
        dismiss()
        Task {
            switch subject {
            case .new: await model.addRemote(named: name, url: url, pushURL: pushURL)
            case .existing(let remote): await model.editRemote(remote, name: name, url: url, pushURL: pushURL)
            }
        }
    }
}
