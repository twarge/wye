import Clibgit2
import Foundation

/// A file or folder in a commit's tree.
public struct TreeEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case directory
        case file
        case executable
        case symlink
        /// A submodule: the entry records a commit of another repository.
        case submodule
    }

    public let name: String
    /// The path from the top of the tree, such as `Sources/main.swift`.
    public let path: String
    /// The blob, tree or (for a submodule) commit the entry names.
    public let objectID: OID
    public let kind: Kind

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }
}

/// A file's contents at a commit.
public struct FileContent: Hashable, Sendable {
    public enum Contents: Hashable, Sendable {
        case text(String)
        /// Bytes that are not text, such as an image.
        case binary(Data)
        /// Not read, because the file is larger than the limit asked for.
        case tooLarge
    }

    public let path: String
    public let objectID: OID
    /// The size in bytes.
    public let size: Int
    public let contents: Contents
}

extension Repository {
    /// The entries of one folder of a commit's tree, in git's order; the top
    /// of the tree when `directory` is empty. A tree is read one folder at a
    /// time, so a large one costs only what is opened.
    public func treeEntries(in commitID: OID, at directory: String = "") throws -> [TreeEntry] {
        let tree = try subtree(at: directory, in: commitID)
        defer { git_tree_free(tree) }
        let prefix = directory.isEmpty ? "" : directory + "/"
        return (0..<git_tree_entrycount(tree)).compactMap { index in
            guard let entry = git_tree_entry_byindex(tree, index) else { return nil }
            let name = String(cString: git_tree_entry_name(entry))
            return TreeEntry(
                name: name,
                path: prefix + name,
                objectID: OID(git_tree_entry_id(entry)),
                kind: TreeEntry.Kind(git_tree_entry_filemode(entry))
            )
        }
    }

    /// A file's contents at a commit. A file larger than `limit` bytes is
    /// measured but not read, so asking about one never loads it whole.
    public func fileContent(at path: String, in commitID: OID, limit: Int = 2 << 20) throws -> FileContent {
        let commit = try lookupCommit(commitID)
        defer { git_commit_free(commit) }
        let tree = try tree(of: commit)
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        try check(git_tree_entry_bypath(&entry, tree, path))
        defer { git_tree_entry_free(entry) }
        guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else {
            throw GitError(code: GIT_EINVALIDSPEC.rawValue, message: "“\(path)” is not a file.")
        }
        var oid = git_tree_entry_id(entry).pointee
        let id = OID(oid)

        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, pointer))
        defer { git_odb_free(odb) }
        var size = 0
        var type = GIT_OBJECT_INVALID
        try check(git_odb_read_header(&size, &type, odb, &oid))
        guard size <= limit else {
            return FileContent(path: path, objectID: id, size: size, contents: .tooLarge)
        }

        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, pointer, &oid))
        defer { git_blob_free(blob) }
        let data = Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
        let contents: FileContent.Contents = git_blob_is_binary(blob) != 0
            ? .binary(data)
            : .text(String(decoding: data, as: UTF8.self))
        return FileContent(path: path, objectID: id, size: data.count, contents: contents)
    }

    /// The tree of a folder at a commit. The caller frees it.
    private func subtree(at directory: String, in commitID: OID) throws -> OpaquePointer? {
        let commit = try lookupCommit(commitID)
        defer { git_commit_free(commit) }
        let root = try tree(of: commit)
        guard !directory.isEmpty else { return root }
        defer { git_tree_free(root) }
        var entry: OpaquePointer?
        try check(git_tree_entry_bypath(&entry, root, directory))
        defer { git_tree_entry_free(entry) }
        guard git_tree_entry_type(entry) == GIT_OBJECT_TREE else {
            throw GitError(code: GIT_EINVALIDSPEC.rawValue, message: "“\(directory)” is not a folder.")
        }
        var object: OpaquePointer?
        try check(git_tree_entry_to_object(&object, pointer, entry))
        return object
    }

    /// What a tree records at a path, or `nil` when the path is not in it.
    /// Two equal keys mean the same content and mode, as git compares them.
    func entryKey(at path: String, in tree: OpaquePointer?) -> TreeEntryKey? {
        guard let tree else { return nil }
        if path.isEmpty {
            return TreeEntryKey(id: OID(git_tree_id(tree)), mode: GIT_FILEMODE_TREE.rawValue)
        }
        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0 else { return nil }
        defer { git_tree_entry_free(entry) }
        return TreeEntryKey(id: OID(git_tree_entry_id(entry)), mode: git_tree_entry_filemode(entry).rawValue)
    }
}

struct TreeEntryKey: Hashable {
    var id: OID
    var mode: UInt32
}

extension TreeEntry.Kind {
    init(_ mode: git_filemode_t) {
        switch mode {
        case GIT_FILEMODE_TREE: self = .directory
        case GIT_FILEMODE_BLOB_EXECUTABLE: self = .executable
        case GIT_FILEMODE_LINK: self = .symlink
        case GIT_FILEMODE_COMMIT: self = .submodule
        default: self = .file
        }
    }
}
