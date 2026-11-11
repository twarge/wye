import GitKit
import SwiftUI

/// Clones a repository from a URL, then adds it to the library and opens it.
struct CloneSheet: View {
    /// An address to start with, from a link or the share sheet.
    var initialAddress = ""
    var open: (RepositoryBookmark) -> Void

    @Environment(RepositoryLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var name = ""
    /// Whether the user typed a name, which then stops following the URL.
    @State private var hasEditedName = false
    /// The folder the clone goes into, on macOS.
    @State private var parent: URL?
    @State private var isChoosingFolder = false
    @State private var activity: RemoteOperations.Activity?
    @State private var credentials = CredentialBroker()
    @State private var error: PresentedError?
    @State private var isBrowsingAccounts = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $url, prompt: Text("https://example.com/owner/project.git or git@example.com:owner/project.git"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                        .onChange(of: url) {
                            if !hasEditedName { name = Self.suggestedName(for: url) }
                        }
                    TextField("Name", text: Binding { name } set: {
                        name = $0
                        hasEditedName = true
                    })
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                    Button("Clone from Account…", systemImage: "person.crop.circle") { isBrowsingAccounts = true }
                } footer: {
                    Text("An HTTPS or SSH address. Twig asks for an access token or an SSH key if the host wants one.")
                }
                .disabled(activity != nil)

                Section {
                    if Platform.clonesIntoChosenFolder {
                        LabeledContent("Location") {
                            HStack {
                                Text(parent?.lastPathComponent ?? "None")
                                    .foregroundStyle(parent == nil ? .secondary : .primary)
                                Button("Choose…") { isChoosingFolder = true }
                            }
                        }
                    } else {
                        LabeledContent("Location", value: "Twig’s Documents")
                    }
                }
                .disabled(activity != nil)

                if let activity {
                    Section {
                        RemoteActivityView(activity: activity) { activity.transfer.cancel() }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Clone Repository")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        if let activity {
                            activity.transfer.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clone") { clone() }
                        .disabled(destination == nil || activity != nil)
                }
            }
        }
        .frame(minWidth: 440)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): parent = url
            case .failure(let failure): error = PresentedError(failure)
            }
        }
        .credentialPrompts(credentials)
        .sheet(isPresented: $isBrowsingAccounts) {
            CloneFromAccountSheet { url = $0 }
        }
        .alert(for: $error)
        .interactiveDismissDisabled(activity != nil)
        .onAppear {
            if url.isEmpty { url = initialAddress }
        }
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The folder to clone into, once there is enough to name it.
    private var destination: URL? {
        guard !trimmedURL.isEmpty, !trimmedName.isEmpty, !trimmedName.contains("/") else { return nil }
        let base = Platform.clonesIntoChosenFolder ? parent : URL.documentsDirectory
        return base?.appending(path: trimmedName, directoryHint: .isDirectory)
    }

    /// `project` for `https://example.com/owner/project.git`.
    static func suggestedName(for url: String) -> String {
        let last = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    private func clone() {
        guard let destination else { return }
        let source = trimmedURL
        let parent = parent
        Task {
            // A folder picked on macOS is only open to the app while accessed.
            let isScoped = parent?.startAccessingSecurityScopedResource() ?? false
            defer {
                if isScoped { parent?.stopAccessingSecurityScopedResource() }
            }
            let logged = ActivityLog.shared.begin("Clone", repository: destination.lastPathComponent)
            do {
                try await credentials.run {
                    let transfer = Transfer()
                    activity = RemoteOperations.Activity(title: "Cloning", transfer: transfer)
                    Task {
                        for await progress in transfer.progress where activity?.transfer === transfer {
                            activity?.progress = progress
                        }
                    }
                    _ = try await Repository.clone(
                        from: source, to: destination, credentials: CredentialStore.shared, transfer: transfer
                    )
                }
                let bookmark = try library.add(destination)
                ActivityLog.shared.finish(logged, error: nil, transfer: activity?.progress)
                activity = nil
                dismiss()
                open(bookmark)
            } catch is CancellationError {
                ActivityLog.shared.finish(logged, .cancelled)
                activity = nil
            } catch {
                ActivityLog.shared.finish(logged, error: error, transfer: activity?.progress)
                activity = nil
                self.error = PresentedError(error)
            }
        }
    }
}
