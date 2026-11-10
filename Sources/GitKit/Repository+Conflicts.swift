import Clibgit2
import Foundation

/// One side of a conflict.
public enum ConflictSide: Hashable, Sendable {
    /// The version on the branch being merged into: `HEAD`. During a rebase
    /// that is the branch being rebased onto, as with git.
    case ours
    /// The version being merged in, or the commit being replayed.
    case theirs
}

extension Repository {
    /// Resolves a conflicted file by taking one side's version whole, in the
    /// index and in the working tree. The other side's changes and any edits
    /// made to the file while resolving are lost. If that side deleted the
    /// file, the file is deleted.
    public func resolveConflict(at path: String, using side: ConflictSide) throws {
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))

        var ancestor: UnsafePointer<git_index_entry>?
        var ours: UnsafePointer<git_index_entry>?
        var theirs: UnsafePointer<git_index_entry>?
        let code = git_index_conflict_get(&ancestor, &ours, &theirs, index, path)
        if code == GIT_ENOTFOUND.rawValue { throw WorkingCopyError.notConflicted(path: path) }
        try check(code)

        // Copied before the conflict is removed, which frees the entries.
        var chosen = (side == .ours ? ours : theirs)?.pointee
        try check(git_index_conflict_remove(index, path))

        if chosen != nil {
            try path.withCString { cPath in
                chosen!.path = cPath
                // Stage 0: an ordinary, resolved entry.
                chosen!.flags &= ~UInt16(GIT_INDEX_ENTRY_STAGEMASK)
                try check(git_index_add(index, &chosen!))
            }
            try check(git_index_write(index))

            var options = git_checkout_options()
            try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
            options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
            try withStringArray([path]) { paths in
                options.paths = paths
                _ = try check(git_checkout_index(pointer, index, &options))
            }
        } else {
            try check(git_index_write(index))
            if let workingDirectory = git_repository_workdir(pointer).map({ String(cString: $0) }) {
                let file = URL(filePath: workingDirectory).appending(path: path)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    /// Records conflicted files as resolved, as they now are in the working
    /// tree. A file that is gone is recorded as deleted.
    public func markResolved(_ paths: [String]) throws {
        try stage(paths)
    }
}
