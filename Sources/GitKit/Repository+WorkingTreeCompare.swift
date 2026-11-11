import Clibgit2
import Foundation

/// Two of the working tree, the index and `HEAD`, compared as a whole.
public enum WorkingTreeComparison: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Everything not committed, staged or not: `git diff HEAD`.
    case workingTreeToHead
    /// What is not staged: `git diff`.
    case workingTreeToIndex
    /// What is staged: `git diff --cached`.
    case indexToHead

    public var id: Self { self }
}

extension Repository {
    /// Every file that differs between two of the working tree, the index
    /// and `HEAD`, with its diff, as `git diff HEAD`, `git diff` and
    /// `git diff --cached` list them. Untracked files are left out, as git
    /// leaves them out. Before the first commit, `HEAD` is empty.
    public func changes(
        in comparison: WorkingTreeComparison, options diffOptions: DiffOptions = .standard
    ) throws -> [FileDiff] {
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        diffOptions.apply(to: &options)
        // Another git may have changed the index on disk since libgit2 read it.
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))
        let head = try headCommit()
        defer { git_commit_free(head) }
        let headTree = try tree(of: head)
        defer { git_tree_free(headTree) }

        var diff: OpaquePointer?
        switch comparison {
        case .workingTreeToHead:
            try check(git_diff_tree_to_workdir_with_index(&diff, pointer, headTree, &options))
        case .workingTreeToIndex:
            try check(git_diff_index_to_workdir(&diff, pointer, nil, &options))
        case .indexToHead:
            try check(git_diff_tree_to_index(&diff, pointer, headTree, nil, &options))
        }
        defer { git_diff_free(diff) }
        try check(git_diff_find_similar(diff, nil))
        let isWorkingTree = comparison != .indexToHead
        return withSubmoduleCommits(try DiffBuilder.files(in: diff, newSideIsWorkingTree: isWorkingTree), workingCopy: isWorkingTree)
    }
}
