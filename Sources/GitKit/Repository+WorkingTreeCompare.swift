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
        var options = try workingTreeDiffOptions(diffOptions)
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

    /// Every file that differs between a commit and the working tree,
    /// staged or not, with its diff, as `git diff <commit>` lists them.
    /// Untracked files are left out, as git leaves them out.
    public func changes(since commit: OID, options diffOptions: DiffOptions = .standard) throws -> [FileDiff] {
        var options = try workingTreeDiffOptions(diffOptions)
        let base = try lookupCommit(commit)
        defer { git_commit_free(base) }
        let baseTree = try tree(of: base)
        defer { git_tree_free(baseTree) }

        var diff: OpaquePointer?
        try check(git_diff_tree_to_workdir_with_index(&diff, pointer, baseTree, &options))
        defer { git_diff_free(diff) }
        try check(git_diff_find_similar(diff, nil))
        return withSubmoduleCommits(try DiffBuilder.files(in: diff, newSideIsWorkingTree: true), workingCopy: true)
    }

    /// The options for a diff against the working tree, with the index read
    /// again first: another git may have changed it on disk since libgit2
    /// read it.
    private func workingTreeDiffOptions(_ diffOptions: DiffOptions) throws -> git_diff_options {
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        diffOptions.apply(to: &options)
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))
        return options
    }
}
