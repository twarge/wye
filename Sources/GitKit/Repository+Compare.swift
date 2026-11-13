import Clibgit2
import Foundation

/// How two commits differ: the commits each has that the other lacks, and
/// the change from the first one's files to the second's.
public struct Comparison: Hashable, Sendable {
    public let left: OID
    public let right: OID
    /// Commits reachable from `left` but not `right`, newest first; at most
    /// the limit asked for, out of `leftCount`.
    public let onlyLeft: [Commit]
    public let onlyRight: [Commit]
    public let leftCount: Int
    public let rightCount: Int
    /// What changes going from `left`'s tree to `right`'s, as `git diff left right`.
    public let files: [FileDiff]
}

extension Repository {
    /// The commit a revision names: a hash or a prefix of one, a branch, a
    /// tag, `HEAD~2` and anything else git's revision syntax allows.
    public func resolveRevision(_ revision: String) throws -> OID {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, pointer, revision.trimmingCharacters(in: .whitespaces)))
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        try check(git_object_peel(&commit, object, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }
        return OID(git_object_id(commit))
    }

    /// Compares two commits. Lists at most `limit` commits on each side,
    /// though it counts them all.
    public func compare(_ left: OID, _ right: OID, limit: Int = 500) throws -> Comparison {
        var leftOID = left.raw, rightOID = right.raw
        var ahead = 0, behind = 0
        try check(git_graph_ahead_behind(&ahead, &behind, pointer, &leftOID, &rightOID))

        let leftCommit = try lookupCommit(left)
        defer { git_commit_free(leftCommit) }
        let rightCommit = try lookupCommit(right)
        defer { git_commit_free(rightCommit) }
        let leftTree = try tree(of: leftCommit)
        defer { git_tree_free(leftTree) }
        let rightTree = try tree(of: rightCommit)
        defer { git_tree_free(rightTree) }

        return Comparison(
            left: left,
            right: right,
            onlyLeft: try commits(in: left, notIn: right, limit: limit),
            onlyRight: try commits(in: right, notIn: left, limit: limit),
            leftCount: ahead,
            rightCount: behind,
            files: try treeDiff(
                from: leftTree, to: rightTree, sources: (DiffBuilder.source(leftCommit), DiffBuilder.source(rightCommit))
            )
        )
    }

    private func commits(in included: OID, notIn excluded: OID, limit: Int) throws -> [Commit] {
        var walkPointer: OpaquePointer?
        try check(git_revwalk_new(&walkPointer, pointer))
        let walk = Walk(pointer: walkPointer!)
        try check(git_revwalk_sorting(walk.pointer, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue))
        var push = included.raw, hide = excluded.raw
        try check(git_revwalk_push(walk.pointer, &push))
        try check(git_revwalk_hide(walk.pointer, &hide))
        var commits: [Commit] = []
        var oid = git_oid()
        while commits.count < limit {
            let code = git_revwalk_next(&oid, walk.pointer)
            if code == GIT_ITEROVER.rawValue { break }
            try check(code)
            let commit = try lookupCommit(OID(oid))
            defer { git_commit_free(commit) }
            commits.append(Commit(commit))
        }
        return commits
    }
}
