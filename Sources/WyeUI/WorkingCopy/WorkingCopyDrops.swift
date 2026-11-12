import GitKit
import SwiftUI

extension View {
    /// Makes a row draggable as a file, when there is a file to drag.
    @ViewBuilder
    func fileDrag(_ drag: FileDrag?) -> some View {
        if let drag {
            draggable(drag)
        } else {
            self
        }
    }

    /// Takes files dropped on the working copy: a patch file is offered to
    /// be applied, as Apply Patch… does; other files are copied into the
    /// repository's folder, once asked.
    func workingCopyDrops(_ model: RepositoryModel) -> some View {
        modifier(WorkingCopyDrops(model: model))
    }
}

private struct WorkingCopyDrops: ViewModifier {
    var model: RepositoryModel
    @State private var pendingFiles: PendingFiles?

    private struct PendingFiles: Identifiable {
        let id = UUID()
        var urls: [URL]
    }

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                switch WorkingCopyDrop.make(urls, repository: model.repository.url) {
                case .patch(let url):
                    readPatch(url)
                    return true
                case .files(let urls):
                    pendingFiles = PendingFiles(urls: urls)
                    return true
                case nil:
                    return false
                }
            }
            .confirmationDialog(
                title, isPresented: Binding { pendingFiles != nil } set: { if !$0 { pendingFiles = nil } },
                titleVisibility: .visible, presenting: pendingFiles
            ) { files in
                Button(files.urls.count == 1 ? "Copy into Repository" : "Copy \(files.urls.count) Items into Repository") {
                    Task { await model.copyIntoRepository(files.urls) }
                }
            } message: { _ in
                Text("They are copied to the top of “\(model.name)” and show as untracked files. Nothing already there is replaced.")
            }
    }

    private var title: String {
        guard let urls = pendingFiles?.urls else { return "" }
        return urls.count == 1 ? "Add “\(urls[0].lastPathComponent)” to the repository?" : "Add \(urls.count) items to the repository?"
    }

    private func readPatch(_ url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        do {
            model.history.requests.importedPatch = ImportedPatch(name: url.lastPathComponent, data: try Data(contentsOf: url))
        } catch {
            model.report(error)
        }
    }
}

extension RepositoryModel {
    /// Copies files and folders dropped on the working copy to the top of
    /// the repository's folder. One already there stops the copy, so a drop
    /// never replaces anything.
    func copyIntoRepository(_ urls: [URL]) async {
        let folder = repository.url
        do {
            try await Task.detached(priority: .userInitiated) {
                for url in urls {
                    let isScoped = url.startAccessingSecurityScopedResource()
                    defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
                    let destination = folder.appending(path: url.lastPathComponent)
                    guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
                        throw FileAlreadyExists(name: url.lastPathComponent)
                    }
                    try FileManager.default.copyItem(at: url, to: destination)
                }
            }.value
        } catch {
            report(error, during: "Copy Files")
        }
        await refresh()
    }
}
