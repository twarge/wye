import Clibgit2
import Foundation

/// A file or folder written out as one side of a comparison has it.
public struct ExportedItem: Hashable, Sendable {
    public var url: URL
    public var isFolder: Bool
    /// The bytes written, in all.
    public var size: Int
}

/// An export that would have written more than it was allowed to.
public struct ExportTooLarge: LocalizedError, Hashable, Sendable {
    public var limit: Int

    public var errorDescription: String? {
        "It is larger than \(limit.formatted(.byteCount(style: .file)))."
    }
}

extension Repository {
    /// Writes the file or folder at `path`, as `source` has it, to
    /// `destination`, which must not exist yet: a whole folder, such as a
    /// document package git keeps as many files, can then be previewed or
    /// dragged out as one. The top of the tree when `path` is empty.
    ///
    /// Returns `nil` when `source` has nothing at `path`. Submodules and
    /// symbolic links inside a folder are left out, and so is the working
    /// tree's `.git`. Throws `ExportTooLarge`, having removed what it wrote,
    /// rather than write more than `limit` bytes.
    public func export(
        _ path: String, from source: ContentSource, to destination: URL, limit: Int
    ) throws -> ExportedItem? {
        var writer = ExportWriter(destination: destination, limit: limit)
        do {
            let isFolder: Bool? = switch source {
            case .commit(let id): try exportTree(path, of: id, writer: &writer)
            case .index: try exportIndex(path, writer: &writer)
            case .workingTree: try exportWorkingTree(path, writer: &writer)
            }
            guard let isFolder else { return nil }
            return ExportedItem(url: destination, isFolder: isFolder, size: writer.size)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: A tree

    /// Whether what was written is a folder; `nil` when there is nothing at `path`.
    private func exportTree(_ path: String, of id: OID, writer: inout ExportWriter) throws -> Bool? {
        var oid = id.raw
        var object: OpaquePointer?
        try check(git_object_lookup(&object, pointer, &oid, GIT_OBJECT_ANY))
        defer { git_object_free(object) }
        // A commit stands for its tree.
        var root: OpaquePointer?
        try check(git_object_peel(&root, object, GIT_OBJECT_TREE))
        defer { git_tree_free(root) }
        guard !path.isEmpty else {
            try writeTree(root, at: "", writer: &writer)
            return true
        }
        var entry: OpaquePointer?
        let code = git_tree_entry_bypath(&entry, root, path)
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try check(code)
        defer { git_tree_entry_free(entry) }
        switch git_tree_entry_type(entry) {
        case GIT_OBJECT_TREE:
            var subtree: OpaquePointer?
            try check(git_tree_entry_to_object(&subtree, pointer, entry))
            defer { git_object_free(subtree) }
            try writeTree(subtree, at: "", writer: &writer)
            return true
        case GIT_OBJECT_BLOB:
            try writeBlob(OID(git_tree_entry_id(entry)), mode: git_tree_entry_filemode(entry).rawValue, at: "", writer: &writer)
            return false
        default:
            return nil
        }
    }

    private func writeTree(_ tree: OpaquePointer?, at folder: String, writer: inout ExportWriter) throws {
        try writer.makeFolder(at: folder)
        for index in 0..<git_tree_entrycount(tree) {
            guard let entry = git_tree_entry_byindex(tree, index) else { continue }
            let name = String(cString: git_tree_entry_name(entry))
            guard ExportWriter.isSafe(name) else { continue }
            let path = folder.isEmpty ? name : folder + "/" + name
            switch git_tree_entry_type(entry) {
            case GIT_OBJECT_TREE:
                var subtree: OpaquePointer?
                try check(git_tree_entry_to_object(&subtree, pointer, entry))
                defer { git_object_free(subtree) }
                try writeTree(subtree, at: path, writer: &writer)
            case GIT_OBJECT_BLOB:
                let mode = git_tree_entry_filemode(entry).rawValue
                guard mode != GIT_FILEMODE_LINK.rawValue else { continue }
                try writeBlob(OID(git_tree_entry_id(entry)), mode: mode, at: path, writer: &writer)
            default:
                continue
            }
        }
    }

    /// Writes a blob's bytes, checking its size before reading it.
    private func writeBlob(_ id: OID, mode: UInt32, at path: String, writer: inout ExportWriter) throws {
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, pointer))
        defer { git_odb_free(odb) }
        var oid = id.raw
        var size = 0
        var type = GIT_OBJECT_INVALID
        try check(git_odb_read_header(&size, &type, odb, &oid))
        try writer.reserve(size)
        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, pointer, &oid))
        defer { git_blob_free(blob) }
        let data = Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
        try writer.write(data, at: path, isExecutable: mode == GIT_FILEMODE_BLOB_EXECUTABLE.rawValue)
    }

    // MARK: The index

    private func exportIndex(_ path: String, writer: inout ExportWriter) throws -> Bool? {
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        defer { git_index_free(index) }
        // Another git may have changed it on disk since libgit2 read it.
        try check(git_index_read(index, 0))
        let prefix = path.isEmpty ? "" : path + "/"
        var isFolder: Bool?
        for position in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, position),
                  git_index_entry_stage(entry) == 0 else { continue }
            let entryPath = String(cString: entry.pointee.path)
            let mode = entry.pointee.mode
            guard mode != GIT_FILEMODE_COMMIT.rawValue, mode != GIT_FILEMODE_LINK.rawValue else { continue }
            if entryPath == path {
                try writeBlob(OID(entry.pointee.id), mode: mode, at: "", writer: &writer)
                return false
            }
            guard entryPath.hasPrefix(prefix) else { continue }
            let inner = String(entryPath.dropFirst(prefix.count))
            guard inner.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ ExportWriter.isSafe(String($0)) }) else {
                continue
            }
            if isFolder == nil {
                try writer.makeFolder(at: "")
                isFolder = true
            }
            try writeBlob(OID(entry.pointee.id), mode: mode, at: inner, writer: &writer)
        }
        return isFolder
    }

    // MARK: The working tree

    private func exportWorkingTree(_ path: String, writer: inout ExportWriter) throws -> Bool? {
        guard let root = git_repository_workdir(pointer) else { return nil }
        let top = URL(filePath: String(cString: root), directoryHint: .isDirectory)
        let source = path.isEmpty ? top : top.appending(path: path)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            let size = (try manager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
            try writer.reserve(size)
            try writer.copy(source, to: "")
            return false
        }
        // Measured first, so nothing is copied that would not fit.
        let children = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".git" }
        for child in children {
            try writer.reserve(Self.size(of: child))
        }
        try writer.makeFolder(at: "")
        for child in children {
            try writer.copy(child, to: child.lastPathComponent)
        }
        return true
    }

    /// The bytes in a file, or in every file inside a folder.
    private static func size(of url: URL) throws -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isRegularFile == true { return values.fileSize ?? 0 }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}

/// Writes an export's files under its destination, keeping count of the
/// bytes against the limit.
private struct ExportWriter {
    let destination: URL
    let limit: Int
    private(set) var size = 0

    init(destination: URL, limit: Int) {
        self.destination = destination
        self.limit = limit
    }

    /// Whether a name from a tree or the index can be written as it is,
    /// without leaving the destination.
    static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name != ".git" && !name.contains("/")
    }

    mutating func reserve(_ bytes: Int) throws {
        size += bytes
        guard size <= limit else { throw ExportTooLarge(limit: limit) }
    }

    private func url(for path: String) -> URL {
        path.isEmpty ? destination : destination.appending(path: path)
    }

    func makeFolder(at path: String) throws {
        try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
    }

    func write(_ data: Data, at path: String, isExecutable: Bool) throws {
        let file = url(for: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        if isExecutable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    /// Copies a file or folder from disk, as a clone where the volume can.
    func copy(_ source: URL, to path: String) throws {
        let target = url(for: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
    }
}
