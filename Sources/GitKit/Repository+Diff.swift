import Clibgit2
import Foundation

extension Repository {
    /// What a commit changed, compared with its first parent, or for a merge
    /// with the parent at `parentIndex`. A stash is a commit too, so this
    /// also shows what a stash holds.
    public func changes(in commitID: OID, parent parentIndex: Int = 0) throws -> [FileDiff] {
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

        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, pointer, oldTree, newTree, nil))
        defer { git_diff_free(diff) }
        try check(git_diff_find_similar(diff, nil))
        return try DiffBuilder.files(in: diff)
    }

    /// A file's changes between `HEAD` and the index.
    public func stagedDiff(of path: String) throws -> FileDiff? {
        let head = try headCommit()
        defer { git_commit_free(head) }
        let headTree = try tree(of: head)
        defer { git_tree_free(headTree) }

        return try withDiffOptions(for: path, flags: 0) { options in
            var diff: OpaquePointer?
            try check(git_diff_tree_to_index(&diff, pointer, headTree, nil, &options))
            defer { git_diff_free(diff) }
            return try DiffBuilder.files(in: diff).first
        }
    }

    /// A file's changes between the index and the working tree.
    public func unstagedDiff(of path: String) throws -> FileDiff? {
        let flags = GIT_DIFF_INCLUDE_UNTRACKED.rawValue
            | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue
        return try withDiffOptions(for: path, flags: flags) { options in
            var diff: OpaquePointer?
            try check(git_diff_index_to_workdir(&diff, pointer, nil, &options))
            defer { git_diff_free(diff) }
            return try DiffBuilder.files(in: diff).first
        }
    }

    /// Diff options limited to one file, named literally.
    private func withDiffOptions<Result>(
        for path: String, flags: UInt32, _ body: (inout git_diff_options) throws -> Result
    ) throws -> Result {
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags = flags | GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
        return try withStringArray([path]) { paths in
            options.pathspec = paths
            return try body(&options)
        }
    }
}
