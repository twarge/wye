import Clibgit2
import Foundation

/// A position in a history being read page by page.
public struct HistoryCursor: Hashable, Sendable {
    private let id = UUID()
}

/// Owns a libgit2 revision walk.
final class Walk {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        git_revwalk_free(pointer)
    }
}

extension Repository {
    /// Starts reading a history, newest commit first with parents after their
    /// children. Close the cursor when done with it.
    public func openHistory(_ scope: HistoryScope) throws -> HistoryCursor {
        let walk = try makeWalk(scope, sorting: GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
        let cursor = HistoryCursor()
        walks[cursor] = walk
        return cursor
    }

    /// The next commits of a history, at most `limit`. Empty once it has ended.
    public func nextCommits(from cursor: HistoryCursor, limit: Int) throws -> [Commit] {
        guard let walk = walks[cursor] else { return [] }
        var commits: [Commit] = []
        commits.reserveCapacity(limit)
        var oid = git_oid()
        while commits.count < limit {
            let code = git_revwalk_next(&oid, walk.pointer)
            if code == GIT_ITEROVER.rawValue { break }
            try check(code)
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, pointer, &oid))
            defer { git_commit_free(commit) }
            commits.append(Commit(commit!))
        }
        return commits
    }

    public func closeHistory(_ cursor: HistoryCursor) {
        walks[cursor] = nil
    }

    /// How many commits a history holds.
    public func commitCount(in scope: HistoryScope) throws -> Int {
        let walk = try makeWalk(scope, sorting: GIT_SORT_NONE.rawValue)
        var count = 0
        var oid = git_oid()
        while git_revwalk_next(&oid, walk.pointer) == 0 {
            count += 1
        }
        return count
    }

    public func commit(_ id: OID) throws -> Commit {
        let commit = try lookupCommit(id)
        defer { git_commit_free(commit) }
        return Commit(commit)
    }

    private func makeWalk(_ scope: HistoryScope, sorting: UInt32) throws -> Walk {
        var pointer: OpaquePointer?
        try check(git_revwalk_new(&pointer, self.pointer))
        let walk = Walk(pointer: pointer!)
        try check(git_revwalk_sorting(walk.pointer, sorting))
        switch scope {
        case .allReferences:
            for glob in ["refs/heads", "refs/remotes", "refs/tags"] {
                try check(git_revwalk_push_glob(walk.pointer, glob))
            }
            // Fails on a branch with no commits, which then has no history.
            _ = git_revwalk_push_head(walk.pointer)
        case .reference(let name):
            try check(git_revwalk_push_ref(walk.pointer, name))
        }
        return walk
    }
}
