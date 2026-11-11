import GitKit
import SwiftUI
import UniformTypeIdentifiers

/// A zip of a commit's files, written to a temporary file, on its way to
/// wherever the user saves it.
struct ArchiveExport: Identifiable {
    let id = UUID()
    var document: ArchiveDocument
    var fileName: String
}

/// A zip archive already on disk, handed to the file exporter without
/// reading it into memory first.
struct ArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    var url: URL?

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        url = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url else { throw CocoaError(.fileReadNoSuchFile) }
        return try FileWrapper(url: url)
    }

    /// Where archives wait to be saved.
    static var temporaryFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Wye Exports", directoryHint: .isDirectory)
    }

    /// Throws away archives written for saving, once saved or abandoned.
    static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryFolder)
    }
}

extension RepositoryModel {
    /// Writes the files of a branch, tag or commit to a zip and asks where
    /// to save it. `name` names the archive and the folder inside it, as
    /// `project-v1.0`.
    func exportFiles(of commit: OID, named name: String) async {
        let base = Self.archiveName(repository: self.name, revision: name)
        // One export at a time: an earlier one that was never saved goes.
        ArchiveDocument.removeTemporaryFiles()
        let folder = ArchiveDocument.temporaryFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: base + ".zip")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await repository.writeArchive(of: commit, to: file, prefix: base + "/")
            history.requests.archiveExport = ArchiveExport(document: ArchiveDocument(url: file), fileName: base + ".zip")
        } catch {
            ArchiveDocument.removeTemporaryFiles()
            self.error = PresentedError(error)
        }
    }

    /// `project-feature-login` for the branch `feature/login`: what the
    /// file and its top folder are called. Slashes and colons, which no
    /// file name can hold everywhere, become dashes.
    static func archiveName(repository: String, revision: String) -> String {
        let cleaned = revision.map { "/:\\".contains($0) ? "-" : $0 }
        return "\(repository)-\(String(cleaned))"
    }
}
