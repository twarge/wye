import Clibgit2
import Foundation

extension Repository {
    /// What a commit changed, compared with its first parent, or for a merge
    /// with the parent at `parentIndex`. A stash is a commit too, so this
    /// also shows what a stash holds.
    public func changes(
        in commitID: OID, parent parentIndex: Int = 0, options diffOptions: DiffOptions = .standard
    ) throws -> [FileDiff] {
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

        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        diffOptions.apply(to: &options)
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, pointer, oldTree, newTree, &options))
        defer { git_diff_free(diff) }
        try check(git_diff_find_similar(diff, nil))
        return withSubmoduleCommits(try DiffBuilder.files(
            in: diff, old: DiffBuilder.source(parent), new: DiffBuilder.source(commit)
        ))
    }

    /// A file's changes between `HEAD` and the index.
    public func stagedDiff(of path: String, options: DiffOptions = .standard) throws -> FileDiff? {
        try withWorkingCopyDiff(of: path, side: .staged, options: options) { diff, sources in
            withSubmoduleCommits(try DiffBuilder.files(in: diff, old: sources.old, new: sources.new)).first
        }
    }

    /// A file's changes between the index and the working tree.
    public func unstagedDiff(of path: String, options: DiffOptions = .standard) throws -> FileDiff? {
        try withWorkingCopyDiff(of: path, side: .unstaged, options: options) { diff, sources in
            withSubmoduleCommits(
                try DiffBuilder.files(in: diff, old: sources.old, new: sources.new), workingCopy: true
            ).first
        }
    }
}
