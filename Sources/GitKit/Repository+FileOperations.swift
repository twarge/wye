import Clibgit2
import Foundation

/// A file operation that cannot go ahead.
public enum FileOperationError: Error, Hashable, Sendable, LocalizedError {
    /// The new path is empty, leaves the working tree, or goes into `.git`.
    case invalidPath(String)
    /// Something is already at the new path.
    case destinationExists(String)
    /// There is no file at the path to move.
    case sourceMissing(String)
    /// The file has a conflict, which has to be resolved before it moves.
    case conflicted(String)
    /// The commit has no file at that path.
    case notInRevision(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            "“\(path)” is not a path inside the working copy."
        case .destinationExists(let path):
            "There is already a file or folder at “\(path)”."
        case .sourceMissing(let path):
            "“\(path)” is not in the working copy."
        case .conflicted(let path):
            "“\(path)” has a conflict. Resolve it before moving it."
        case .notInRevision(let path):
            "That commit has no file at “\(path)”."
        }
    }
}

extension Repository {
    /// The folder of the working tree, ending in `/`.
    private func workingDirectoryPath() throws -> String {
        guard let path = git_repository_workdir(pointer).map({ String(cString: $0) }) else {
            throw RepositoryError.noWorkingDirectory
        }
        return path
    }

    /// Moves or renames a file, as `git mv` does: the file moves on disk,
    /// and a tracked file's index entry moves with it, keeping what was
    /// staged, so the move itself is staged. An untracked file just moves.
    public func move(_ path: String, to newPath: String) throws {
        let root = try workingDirectoryPath()
        let destination = try validatedPath(newPath)
        guard destination != path else { return }

        var information = stat()
        guard lstat(root + path, &information) == 0 else { throw FileOperationError.sourceMissing(path) }
        // A change of case alone names the same file on a volume that
        // ignores case; anything else already there is in the way.
        let isCaseChange = destination.lowercased() == path.lowercased()
        if !isCaseChange, lstat(root + destination, &information) == 0 {
            throw FileOperationError.destinationExists(destination)
        }

        let index = try freshIndex()
        defer { git_index_free(index) }
        if git_index_get_bypath(index, path, 1) != nil || git_index_get_bypath(index, path, 2) != nil {
            throw FileOperationError.conflicted(path)
        }
        let tracked = git_index_get_bypath(index, path, 0)?.pointee

        let destinationURL = URL(filePath: root + destination)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard rename(root + path, root + destination) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: root + destination])
        }

        if var entry = tracked {
            let copy = strdup(destination)
            defer { free(copy) }
            entry.path = UnsafePointer(copy)
            // The path's length lives in the flags; the index works it out again.
            entry.flags &= ~UInt16(GIT_INDEX_ENTRY_NAMEMASK)
            try check(git_index_remove(index, path, 0))
            try check(git_index_add(index, &entry))
            try check(git_index_write(index))
        }
        removeEmptyFolders(above: path, root: root)
    }

    /// Puts a file's contents at a commit into the working tree, as
    /// `git restore --source=<commit>` does. The index is left alone, so
    /// the result shows as an unstaged change; whatever was in the working
    /// tree's copy is overwritten.
    public func restore(_ path: String, from commitID: OID) throws {
        _ = try workingDirectoryPath()
        let commit = try lookupCommit(commitID)
        defer { git_commit_free(commit) }
        let tree = try tree(of: commit)
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0 else { throw FileOperationError.notInRevision(path) }
        defer { git_tree_entry_free(entry) }
        guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { throw FileOperationError.notInRevision(path) }

        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
            | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
            | GIT_CHECKOUT_DONT_UPDATE_INDEX.rawValue
        try withStringArray([path]) { paths in
            options.paths = paths
            _ = try check(git_checkout_tree(pointer, tree, &options))
        }
    }

    /// Whether a path has changes that are not committed, staged or not,
    /// including being untracked. An ignored path or one git does not know
    /// about has none.
    public func hasUncommittedChanges(at path: String) throws -> Bool {
        var flags: UInt32 = 0
        let code = git_status_file(&flags, pointer, path)
        if code == GIT_ENOTFOUND.rawValue { return false }
        try check(code)
        return flags & ~GIT_STATUS_IGNORED.rawValue != 0
    }

    /// A path relative to the working tree, normalized, that stays inside it.
    private func validatedPath(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }),
              components.first?.lowercased() != ".git" else {
            throw FileOperationError.invalidPath(path)
        }
        return components.joined(separator: "/")
    }

    /// Takes away folders a move left empty, as git does.
    private func removeEmptyFolders(above path: String, root: String) {
        var components = path.split(separator: "/").dropLast()
        while !components.isEmpty {
            let folder = root + components.joined(separator: "/")
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder),
                  contents.isEmpty, rmdir(folder) == 0 else { return }
            components = components.dropLast()
        }
    }
}
