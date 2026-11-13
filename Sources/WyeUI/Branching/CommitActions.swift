import GitKit
import SwiftUI
import UniformTypeIdentifiers

extension Commit {
    /// What Copy Commit Info puts on the clipboard: the hash, author, date
    /// and subject.
    var info: String {
        let date = author.date.formatted(Date.FormatStyle(date: .long, time: .shortened))
        return "\(id.hex)\nAuthor: \(author.name) <\(author.email)>\nDate: \(date)\n\n\(summary)"
    }
}

// MARK: Sheets and files

/// Two revisions for the Compare sheet to start from.
struct CompareRequest: Identifiable {
    let id = UUID()
    var from: String
    var to: String
}

/// A commit's patch on its way to a file.
struct PatchExport: Identifiable {
    let id = UUID()
    var document: PatchDocument
    var fileName: String
}

/// A patch file read in, waiting to be told where its changes go.
struct ImportedPatch: Identifiable {
    let id = UUID()
    var name: String
    var data: Data
}

/// What the commit menus ask for that a view has to present: the Compare
/// sheet, saving and opening patch files, and editing a message.
@MainActor
@Observable
final class CommitActionRequests {
    var compare: CompareRequest?
    var patchExport: PatchExport?
    var isImportingPatch = false
    var importedPatch: ImportedPatch?
    /// The commit whose message is being edited: `HEAD`'s.
    var reword: Commit?
    /// A zip of a commit's files, waiting to be saved.
    var archiveExport: ArchiveExport?

    /// Writes a commit's patch and asks where to save it.
    func export(_ commit: Commit, from model: RepositoryModel) async {
        do {
            let text = try await model.repository.formatPatch(for: commit.id)
            patchExport = PatchExport(document: PatchDocument(text: text),
                                      fileName: Repository.patchFileName(for: commit))
        } catch {
            model.report(error)
        }
    }
}

/// A patch as a file to save.
struct PatchDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.patch, .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    /// A patch file, as `git format-patch` names them.
    static let patch = UTType(filenameExtension: "patch", conformingTo: .plainText) ?? .plainText
    static let diffFile = UTType(filenameExtension: "diff", conformingTo: .plainText) ?? .plainText
}

extension View {
    /// Presents what the commit menus ask for.
    func commitActionPresenters(_ model: RepositoryModel) -> some View {
        modifier(CommitActionPresenters(model: model, requests: model.history.requests))
    }
}

private struct CommitActionPresenters: ViewModifier {
    var model: RepositoryModel
    @Bindable var requests: CommitActionRequests

    func body(content: Content) -> some View {
        content
            .sheet(item: $requests.compare) { request in
                CompareView(model: model, from: request.from, to: request.to)
            }
            .sheet(item: $requests.reword) { commit in
                RewordSheet(model: model, commit: commit)
            }
            .fileExporter(
                isPresented: Binding { requests.patchExport != nil } set: { if !$0 { requests.patchExport = nil } },
                document: requests.patchExport?.document,
                contentType: .patch,
                defaultFilename: requests.patchExport?.fileName
            ) { result in
                if case .failure(let failure) = result { model.report(failure) }
            }
            .background {
                // On its own view: one view takes only one file exporter.
                Color.clear
                    .fileExporter(
                        isPresented: Binding { requests.archiveExport != nil } set: { if !$0 { requests.archiveExport = nil } },
                        document: requests.archiveExport?.document,
                        contentType: .zip,
                        defaultFilename: requests.archiveExport?.fileName
                    ) { result in
                        // Once it is written: the export may already be off screen.
                        ArchiveDocument.removeTemporaryFiles()
                        if case .failure(let failure) = result { model.report(failure) }
                    }
            }
            .fileImporter(isPresented: $requests.isImportingPatch, allowedContentTypes: [.patch, .diffFile, .plainText]) { result in
                switch result {
                case .success(let url):
                    let isScoped = url.startAccessingSecurityScopedResource()
                    defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        requests.importedPatch = ImportedPatch(name: url.lastPathComponent, data: try Data(contentsOf: url))
                    } catch {
                        model.report(error)
                    }
                case .failure(let failure):
                    model.report(failure)
                }
            }
            .confirmationDialog(
                "Apply “\(requests.importedPatch?.name ?? "")”?",
                isPresented: Binding { requests.importedPatch != nil } set: { if !$0 { requests.importedPatch = nil } },
                titleVisibility: .visible,
                presenting: requests.importedPatch
            ) { patch in
                Button("Apply to Working Copy") { apply(patch, to: .workingTree) }
                Button("Apply and Stage") { apply(patch, to: .workingTreeAndIndex) }
            } message: { _ in
                Text("Its changes are made to the files only if every file takes them. Undo reverses it.")
            }
    }

    private func apply(_ patch: ImportedPatch, to target: PatchTarget) {
        Task {
            await model.perform(.applyPatch(toIndex: false)) { try await $0.applyPatch(patch.data, to: target) }
        }
    }
}

/// Edits the last commit's message, leaving its changes and the index alone.
struct RewordSheet: View {
    var model: RepositoryModel
    var commit: Commit

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var isLoaded = false
    /// The remote branch that already has the commit, if any.
    @State private var pushedTo: String?

    var body: some View {
        SheetStack("Edit Message") {
            Form {
                SheetTitleSection()
                Section {
                    TextEditor(text: $message)
                        .font(.body)
                        .frame(minHeight: 140)
                        .disabled(!isLoaded)
                } footer: {
                    if let pushedTo {
                        Text("This commit is already on \(pushedTo). Changing its message here makes a new commit, "
                             + "and \(pushedTo) only takes it with a force push.")
                    } else {
                        Text("Only the message changes. Staged changes stay staged.")
                    }
                }
            }
            .groupedFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isLoaded || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .sheetMinimumSize(width: 460, height: 300)
        .task {
            let repository = model.repository
            message = (try? await repository.lastCommitMessage())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? commit.summary
            pushedTo = try? await repository.remoteBranch(containing: commit.id)
            isLoaded = true
        }
    }

    private func save() {
        let message = message
        let expected = commit.id
        dismiss()
        Task {
            await model.perform(.reword) { repository in
                // The sheet was opened for this commit; HEAD may have moved since.
                guard try await repository.head().target == expected else { throw HeadMoved() }
                try await repository.rewordHead(message: message)
            }
        }
    }
}

private struct HeadMoved: LocalizedError {
    var errorDescription: String? {
        "HEAD has moved since the message was opened, so it was left as it is."
    }
}
