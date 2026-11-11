import Clibgit2
import Foundation

/// A position in a history being read page by page.
public struct HistoryCursor: Hashable, Sendable {
    private let id = UUID()
}

/// How a history is read: in which order, and whether it follows merges.
public struct HistoryOptions: Hashable, Sendable, Codable {
    public enum Order: String, Hashable, Sendable, Codable, CaseIterable {
        /// Newest first by commit date, parents after all their children:
        /// `git log --date-order`.
        case date
        /// Parents after all their children, each line of history kept
        /// together rather than interleaved by date: `git log --topo-order`.
        case topological
    }

    public var order: Order
    /// Follows only the first parent of each merge: `git log --first-parent`.
    public var firstParentOnly: Bool
    /// When not empty, the whole history lists only what these references,
    /// by full name, lead to: `git log <branch>…`. A history of one
    /// reference keeps to that reference.
    public var includedReferences: [String]
    /// References, by full name, whose commits are left out, as with
    /// `git log ^<branch>`. Commits another listed reference also leads to
    /// are left out too: that is what hiding a branch means in git.
    public var hiddenReferences: [String]

    public init(
        order: Order = .date, firstParentOnly: Bool = false,
        includedReferences: [String] = [], hiddenReferences: [String] = []
    ) {
        self.order = order
        self.firstParentOnly = firstParentOnly
        self.includedReferences = includedReferences
        self.hiddenReferences = hiddenReferences
    }

    private enum CodingKeys: String, CodingKey {
        case order, firstParentOnly, includedReferences, hiddenReferences
    }

    /// Options saved before the reference filters existed still read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        order = try container.decodeIfPresent(Order.self, forKey: .order) ?? .date
        firstParentOnly = try container.decodeIfPresent(Bool.self, forKey: .firstParentOnly) ?? false
        includedReferences = try container.decodeIfPresent([String].self, forKey: .includedReferences) ?? []
        hiddenReferences = try container.decodeIfPresent([String].self, forKey: .hiddenReferences) ?? []
    }

    var sorting: UInt32 {
        switch order {
        case .date: GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue
        case .topological: GIT_SORT_TOPOLOGICAL.rawValue
        }
    }
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
    /// children, in the order `options` asks for. Close the cursor when done
    /// with it.
    public func openHistory(_ scope: HistoryScope, options: HistoryOptions = HistoryOptions()) throws -> HistoryCursor {
        let walk = try makeWalk(scope, sorting: options.sorting, options: options)
        if options.firstParentOnly {
            try check(git_revwalk_simplify_first_parent(walk.pointer))
        }
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

    /// The commits a merge brought in: those its other parents lead to and
    /// its first parent does not, as `git rev-list <merge>^2 ^<merge>^1`.
    /// At most `limit`; empty for a commit that is not a merge.
    public func commitsMerged(by id: OID, limit: Int = 50_000) throws -> [OID] {
        var commit: OpaquePointer?
        var raw = id.raw
        try check(git_commit_lookup(&commit, pointer, &raw))
        defer { git_commit_free(commit) }
        let count = git_commit_parentcount(commit)
        guard count > 1, let first = git_commit_parent_id(commit, 0) else { return [] }

        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, pointer))
        defer { git_revwalk_free(walk) }
        for position in 1..<count {
            guard let parent = git_commit_parent_id(commit, position) else { continue }
            try check(git_revwalk_push(walk, parent))
        }
        try check(git_revwalk_hide(walk, first))

        var merged: [OID] = []
        var oid = git_oid()
        while merged.count < limit, git_revwalk_next(&oid, walk) == 0 {
            merged.append(OID(oid))
        }
        return merged
    }

    public func closeHistory(_ cursor: HistoryCursor) {
        walks[cursor] = nil
    }

    /// How many commits a history holds.
    public func commitCount(in scope: HistoryScope, options: HistoryOptions = HistoryOptions()) throws -> Int {
        let walk = try makeWalk(scope, sorting: GIT_SORT_NONE.rawValue, options: options)
        if options.firstParentOnly {
            try check(git_revwalk_simplify_first_parent(walk.pointer))
        }
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

    private func makeWalk(_ scope: HistoryScope, sorting: UInt32, options: HistoryOptions) throws -> Walk {
        var pointer: OpaquePointer?
        try check(git_revwalk_new(&pointer, self.pointer))
        let walk = Walk(pointer: pointer!)
        try check(git_revwalk_sorting(walk.pointer, sorting))
        // A filter naming a branch that has since gone hides or shows nothing.
        for name in options.hiddenReferences {
            _ = git_revwalk_hide_ref(walk.pointer, name)
        }
        switch scope {
        case .allReferences where !options.includedReferences.isEmpty:
            for name in options.includedReferences {
                _ = git_revwalk_push_ref(walk.pointer, name)
            }
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
