import CoreTransferable
import Foundation
import GitKit
import UniformTypeIdentifiers

/// Where files written for a drag or a share wait to be picked up. Emptied
/// when the app starts: nothing can still want one by then.
enum DragFiles {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Wye Drags", directoryHint: .isDirectory)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A new file of this name, in a folder of its own so names never clash.
    static func newFile(named name: String) throws -> URL {
        let folder = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A name that is a path would leave the folder.
        let safe = name.replacing("/", with: "-").replacing(":", with: "-")
        return folder.appending(path: safe.isEmpty ? "file" : safe)
    }
}

/// Commits being dragged or shared. Inside a repository window they are
/// their hashes, one a line, which the sidebar reads back to cherry-pick;
/// dropped on the Finder, the Files app or a message they are a patch file,
/// as `git format-patch` writes one.
struct CommitDrag: Transferable, Sendable {
    var repository: Repository
    var commits: [Commit]

    /// The most commits written into one patch file.
    static let patchLimit = 100

    var text: String { SidebarDragPayload.text(for: commits.map(\.id)) }

    /// A merge has no patch of its own.
    var hasPatch: Bool {
        !commits.isEmpty && commits.count <= Self.patchLimit && !commits.contains(where: \.isMerge)
    }

    /// `0001-fix-the-thing.patch` for one commit; for several, the oldest's
    /// name with how many follow.
    static func fileName(for commits: [Commit]) -> String {
        guard let oldest = commits.last else { return "commits.patch" }
        let name = Repository.patchFileName(for: oldest)
        guard commits.count > 1, name.hasSuffix(".patch") else { return name }
        return name.dropLast(".patch".count) + "-and-\(commits.count - 1)-more.patch"
    }

    /// Writes the commits oldest first, the order `git am` applies them in.
    /// A history lists them newest first.
    func writePatch() async throws -> URL {
        var text = ""
        for commit in commits.reversed() {
            text += try await repository.formatPatch(for: commit.id)
            if !text.hasSuffix("\n") { text += "\n" }
        }
        let file = try DragFiles.newFile(named: Self.fileName(for: commits))
        try Data(text.utf8).write(to: file, options: .atomic)
        return file
    }

    static var transferRepresentation: some TransferRepresentation {
        // Text first: it is what the sidebar's drops ask for, and they must
        // never be handed the patch instead.
        ProxyRepresentation(exporting: \.text)
        FileRepresentation(exportedContentType: .patch) { drag in
            SentTransferredFile(try await drag.writePatch())
        }
        .exportingCondition(\.hasPatch)
    }
}

/// A file being dragged out of a repository window: the one in the working
/// tree, or the file as a commit has it. The receiver always gets a copy,
/// so a drop on the Finder never moves a file out of the repository.
struct FileDrag: Transferable, Sendable {
    var repository: Repository
    var path: String
    /// The commit to take the file from; `nil` for the working tree.
    var commit: OID?

    /// The largest file read out of a commit for a drag.
    static let sizeLimit = 256 << 20

    struct TooLarge: LocalizedError {
        var errorDescription: String? { "The file is too large to drag out of a commit." }
    }

    /// `main.swift` for the working tree's file; `main-1a2b3c4d.swift` for a
    /// commit's, so that it does not pass for the current one.
    static func fileName(for path: String, commit: OID?) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let commit else { return name }
        let hash = commit.abbreviated()
        // A leading dot is the name, not an extension: `.gitignore`.
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "\(name)-\(hash)" }
        return "\(name[..<dot])-\(hash)\(name[dot...])"
    }

    func file() async throws -> URL {
        guard let commit else { return repository.url.appending(path: path) }
        let content = try await repository.fileContent(at: path, in: commit, limit: Self.sizeLimit)
        let data: Data = switch content.contents {
        case .text(let text): Data(text.utf8)
        case .binary(let data): data
        case .tooLarge: throw TooLarge()
        }
        let file = try DragFiles.newFile(named: Self.fileName(for: path, commit: commit))
        try data.write(to: file, options: .atomic)
        return file
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { drag in
            SentTransferredFile(try await drag.file(), allowAccessingOriginalFile: false)
        }
    }
}

/// A stash being dragged out, as a patch of its changes to tracked files.
struct StashDrag: Transferable, Sendable {
    var repository: Repository
    var stash: Stash

    func writePatch() async throws -> URL {
        let text = try await repository.patch(ofStash: stash)
        let file = try DragFiles.newFile(named: "stash-\(stash.index)-\(stash.id.abbreviated()).patch")
        try Data(text.utf8).write(to: file, options: .atomic)
        return file
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .patch) { drag in
            SentTransferredFile(try await drag.writePatch())
        }
    }
}

/// What a drop of files on the working copy is: patches to apply, or files
/// to copy into the repository.
enum WorkingCopyDrop: Hashable {
    case patch(URL)
    case files([URL])

    /// Reads a drop. One patch file is a patch; anything else is files to
    /// add, leaving out what is already inside the repository.
    static func make(_ urls: [URL], repository: URL) -> WorkingCopyDrop? {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return nil }
        if files.count == 1, let file = files.first, ["patch", "diff"].contains(file.pathExtension.lowercased()) {
            return .patch(file)
        }
        var base = repository.standardizedFileURL.path(percentEncoded: false)
        if !base.hasSuffix("/") { base += "/" }
        let outside = files.filter { !$0.standardizedFileURL.path(percentEncoded: false).hasPrefix(base) }
        return outside.isEmpty ? nil : .files(outside)
    }
}

/// A file dropped on the working copy that is already there.
struct FileAlreadyExists: LocalizedError {
    var name: String
    var errorDescription: String? { "“\(name)” is already in the repository. Nothing was replaced." }
}

/// Patch files opened in Wye from another app.
enum PatchFileOpening {
    static func isPatch(_ url: URL) -> Bool {
        url.isFileURL && ["patch", "diff"].contains(url.pathExtension.lowercased())
    }

    /// A patch needs a repository to go into.
    struct NoRepository: LocalizedError {
        var name: String
        var errorDescription: String? {
            "Open the repository “\(name)” is for, then open the patch again."
        }
    }
}
