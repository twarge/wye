import Clibgit2
import Foundation

extension Repository {
    /// The paths, relative to the working tree, that the ignore rules exclude
    /// and that hold nothing tracked: a file not in the index, or a folder
    /// with no file of the index inside it. A change to one of these cannot
    /// change what the working copy shows.
    ///
    /// A tracked file stays visible whatever the ignore rules say, which is
    /// why the index is checked too. Paths that do not exist are judged by
    /// the rules alone.
    public func ignoredUntrackedPaths(among paths: [String]) throws -> Set<String> {
        guard !isBare, !paths.isEmpty else { return [] }
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        defer { git_index_free(index) }
        // Pick up changes another git made since this repository was opened.
        try check(git_index_read(index, 0))

        var ignored: Set<String> = []
        for path in Set(paths) {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard !trimmed.isEmpty else { continue }
            var isIgnored: Int32 = 0
            try check(git_ignore_path_is_ignored(&isIgnored, pointer, trimmed))
            guard isIgnored != 0 else { continue }
            if git_index_get_bypath(index, trimmed, 0) != nil { continue }
            var position = 0
            // Any entry under the path as a folder means something tracked is inside.
            if git_index_find_prefix(&position, index, trimmed + "/") == 0 { continue }
            ignored.insert(path)
        }
        return ignored
    }
}
