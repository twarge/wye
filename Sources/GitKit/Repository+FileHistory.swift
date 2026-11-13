import Clibgit2
import Foundation

/// A commit that changed a file.
public struct FileHistoryEntry: Identifiable, Hashable, Sendable {
    public let commit: Commit
    /// The file's path in this commit; for a deletion, the path it had.
    public let path: String
    /// The path in the parent, when this commit renamed the file.
    public let oldPath: String?
    public let change: FileChange

    public var id: OID { commit.id }
}

/// One page of a file's history.
public struct FileHistoryPage: Hashable, Sendable {
    public var entries: [FileHistoryEntry]
    /// The path to follow on the next page: the file's older name once a
    /// rename has been passed.
    public var path: String
    public var isComplete: Bool
}

extension Repository {
    /// Starts reading the history behind one commit, newest first with
    /// parents after their children. Read it with `nextFileHistory` (or
    /// `nextMatches`) and close it with `closeHistory`.
    public func openHistory(from commitID: OID) throws -> HistoryCursor {
        var walkPointer: OpaquePointer?
        try check(git_revwalk_new(&walkPointer, pointer))
        let walk = Walk(pointer: walkPointer!)
        try check(git_revwalk_sorting(walk.pointer, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue))
        var oid = commitID.raw
        try check(git_revwalk_push(walk.pointer, &oid))
        let cursor = HistoryCursor()
        walks[cursor] = walk
        return cursor
    }

    /// The next commits that changed the file at `path`, following it to its
    /// older name across renames as `git log --follow` does. Pass the page's
    /// `path` back in to read the page after it. Like a search, a page ends
    /// after `limit` entries or `examining` commits.
    public func nextFileHistory(
        from cursor: HistoryCursor, following path: String, limit: Int, examining budget: Int = 2_000
    ) throws -> FileHistoryPage {
        var page = FileHistoryPage(entries: [], path: path, isComplete: false)
        guard let walk = walks[cursor] else {
            page.isComplete = true
            return page
        }
        var examined = 0
        var oid = git_oid()
        while page.entries.count < limit, examined < budget {
            let code = git_revwalk_next(&oid, walk.pointer)
            if code == GIT_ITEROVER.rawValue {
                page.isComplete = true
                break
            }
            try check(code)
            examined += 1
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, pointer, &oid))
            defer { git_commit_free(commit) }
            if let entry = try fileChange(of: page.path, in: commit!) {
                page.entries.append(entry)
                if let oldPath = entry.oldPath {
                    page.path = oldPath
                }
            }
        }
        return page
    }

    /// How a commit changed the file at `path`, or `nil` if it left it as one
    /// of its parents had it.
    private func fileChange(of path: String, in commit: OpaquePointer) throws -> FileHistoryEntry? {
        let tree = try self.tree(of: commit)
        defer { git_tree_free(tree) }
        let own = entryKey(at: path, in: tree)

        var firstParentTree: OpaquePointer?
        defer { git_tree_free(firstParentTree) }
        var firstParentKey: TreeEntryKey?
        for index in 0..<git_commit_parentcount(commit) {
            var parent: OpaquePointer?
            try check(git_commit_parent(&parent, commit, index))
            defer { git_commit_free(parent) }
            let parentTree = try self.tree(of: parent)
            let key = entryKey(at: path, in: parentTree)
            if index == 0 {
                firstParentTree = parentTree
                firstParentKey = key
            } else {
                git_tree_free(parentTree)
            }
            if key == own { return nil }
        }
        if own == nil && firstParentKey == nil { return nil }

        var change: FileChange = own == nil ? .deleted : firstParentKey == nil ? .added : .modified
        var oldPath: String?
        if change == .added, firstParentTree != nil {
            oldPath = try renameSource(of: path, from: firstParentTree, to: tree)
            if oldPath != nil { change = .renamed }
        }
        return FileHistoryEntry(commit: Commit(commit), path: path, oldPath: oldPath, change: change)
    }

    /// One file's diff in a commit, against the parent at `parentIndex`, with
    /// a rename shown as one. `nil` when the commit did not change the file.
    public func fileDiff(in commitID: OID, path: String, parent parentIndex: Int = 0) throws -> FileDiff? {
        let commit = try lookupCommit(commitID)
        defer { git_commit_free(commit) }
        let newTree = try tree(of: commit)
        defer { git_tree_free(newTree) }
        var parent: OpaquePointer?
        if parentIndex < git_commit_parentcount(commit) {
            try check(git_commit_parent(&parent, commit, UInt32(parentIndex)))
        }
        defer { git_commit_free(parent) }
        let oldTree = try tree(of: parent)
        defer { git_tree_free(oldTree) }

        var paths = [path]
        if oldTree != nil, entryKey(at: path, in: oldTree) == nil,
           let source = try renameSource(of: path, from: oldTree, to: newTree) {
            paths.append(source)
        }
        let files = try treeDiff(
            from: oldTree, to: newTree, paths: paths, sources: (DiffBuilder.source(parent), DiffBuilder.source(commit))
        )
        return files.first { $0.path == path } ?? files.first { $0.oldPath == path }
    }

    /// The path a file had in `oldTree`, when `newTree` has it under `path`
    /// because of a rename.
    func renameSource(of path: String, from oldTree: OpaquePointer?, to newTree: OpaquePointer?) throws -> String? {
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, pointer, oldTree, newTree, nil))
        defer { git_diff_free(diff) }
        try findRenames(in: diff)
        for index in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, index)?.pointee,
                  delta.status == GIT_DELTA_RENAMED,
                  let newPath = delta.new_file.path, String(cString: newPath) == path,
                  let oldPath = delta.old_file.path else { continue }
            return String(cString: oldPath)
        }
        return nil
    }

    /// The diff between two trees, as values, with renames found. Limited to
    /// `paths`, named literally, when any are given. `sources` are the
    /// commits the trees are of.
    func treeDiff(
        from oldTree: OpaquePointer?, to newTree: OpaquePointer?, paths: [String] = [],
        sources: (old: ContentSource?, new: ContentSource?)
    ) throws -> [FileDiff] {
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        return try withStringArray(paths) { pathspec in
            if !paths.isEmpty {
                options.pathspec = pathspec
                options.flags |= GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
            }
            var diff: OpaquePointer?
            try check(git_diff_tree_to_tree(&diff, pointer, oldTree, newTree, &options))
            defer { git_diff_free(diff) }
            try findRenames(in: diff)
            return try DiffBuilder.files(in: diff, old: sources.old, new: sources.new)
        }
    }

    private func findRenames(in diff: OpaquePointer?) throws {
        var options = git_diff_find_options()
        try check(git_diff_find_options_init(&options, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)))
        options.flags = GIT_DIFF_FIND_RENAMES.rawValue
        try check(git_diff_find_similar(diff, &options))
    }
}
