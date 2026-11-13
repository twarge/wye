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

/// The top of a history: its first commits, where to read on from, and the
/// commit whose line its graph keeps straight.
public struct HistoryStart: Sendable {
    public var cursor: HistoryCursor
    public var commits: [Commit]
    /// See `Repository.mainLine(of:options:)`.
    public var mainLine: OID?
}

/// Owns a libgit2 revision walk.
final class Walk {
    let pointer: OpaquePointer
    /// Whether it follows first parents only, where a merge stands for the
    /// branch it brought in.
    var firstParentOnly = false
    /// For a contents search, how often its text occurs in each blob read
    /// so far, or `nil` for one not searched: a commit's version of a file
    /// is its child's parent version too, so each is read once.
    var contentCounts: [OID: Int?] = [:]
    /// The text those counts are for.
    var countedText: String?

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
            walk.firstParentOnly = true
        }
        let cursor = HistoryCursor()
        walks[cursor] = walk
        return cursor
    }

    /// Starts reading a history and reads its first commits, at most
    /// `limit`, with the main line of its graph: all a list needs to show
    /// its top, in one turn. `previous` is closed, for a history read again.
    public func startHistory(
        _ scope: HistoryScope, options: HistoryOptions = HistoryOptions(), limit: Int,
        closing previous: HistoryCursor? = nil
    ) throws -> HistoryStart {
        if let previous { closeHistory(previous) }
        let cursor = try openHistory(scope, options: options)
        do {
            let commits = try nextCommits(from: cursor, limit: limit)
            return HistoryStart(cursor: cursor, commits: commits, mainLine: try? mainLine(of: scope, options: options))
        } catch {
            closeHistory(cursor)
            throw error
        }
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
        case .allReferences:
            for tip in try startingCommits(of: scope, options: options).reversed() {
                var id = tip.id.raw
                try check(git_revwalk_push(walk.pointer, &id))
            }
        case .reference(let name):
            try check(git_revwalk_push_ref(walk.pointer, name))
        }
        return walk
    }

    /// What a history of every reference starts from, newest commit first:
    /// the branches, remote branches and tags, and `HEAD`, or the references
    /// the options keep to. Names that lead to no commit, such as a branch
    /// with no commits or a tag of a tree, are passed over.
    ///
    /// The walk takes these in this order, as git takes them for
    /// `git log --topo-order`: lines of history then come out newest first,
    /// and a stale one beside the commit it left, not ahead of everything
    /// because of its name.
    private func startingCommits(of scope: HistoryScope, options: HistoryOptions) throws -> [(id: OID, time: Int64)] {
        let names: [String]
        switch scope {
        case .allReferences where !options.includedReferences.isEmpty:
            names = options.includedReferences
        case .allReferences:
            var all = git_strarray()
            try check(git_reference_list(&all, pointer))
            defer { git_strarray_dispose(&all) }
            let listed = strings(in: all).sorted()
            names = ["refs/heads/", "refs/remotes/", "refs/tags/"].flatMap { prefix in
                listed.filter { $0.hasPrefix(prefix) }
            } + ["HEAD"]
        case .reference(let name):
            names = [name]
        }
        var tips: [(id: OID, time: Int64)] = []
        var seen: Set<OID> = []
        for name in names {
            var reference: OpaquePointer?
            guard git_reference_lookup(&reference, pointer, name) == 0 else { continue }
            defer { git_reference_free(reference) }
            var commit: OpaquePointer?
            guard git_reference_peel(&commit, reference, GIT_OBJECT_COMMIT) == 0 else { continue }
            defer { git_object_free(commit) }
            let id = OID(git_object_id(commit))
            guard seen.insert(id).inserted else { continue }
            tips.append((id, git_commit_time(commit)))
        }
        // Stable, so commits of the same second keep the names' order, as in git.
        return tips.enumerated()
            .sorted { $0.element.time != $1.element.time ? $0.element.time > $1.element.time : $0.offset < $1.offset }
            .map(\.element)
    }
}

extension Repository {
    /// The commit whose line of first parents a graph of this history keeps
    /// straight in its first lane (see `CommitGraph.init(mainLine:)`): for a
    /// history of every reference, `HEAD`, raised to the newest branch or
    /// tag whose first parents lead down to it, such as a branch started on
    /// top of it or a remote branch it is behind; for a history of one
    /// reference, that reference. `nil` when the history does not list it.
    public func mainLine(of scope: HistoryScope, options: HistoryOptions = HistoryOptions()) throws -> OID? {
        let base: OID
        switch scope {
        case .allReferences:
            guard let head = try headCommit() else { return nil }
            base = OID(git_commit_id(head))
            git_commit_free(head)
        case .reference(let name):
            // Through a tag object, for a tag's history.
            var id = git_oid()
            guard git_reference_name_to_id(&id, pointer, name) == 0,
                  let commit = try? peeledCommit(OID(id)) else { return nil }
            base = commit
        }
        let tips = try startingCommits(of: scope, options: options)
        // Listed only when something the history starts from leads to it,
        // and nothing hidden does.
        guard tips.contains(where: { $0.id == base })
                || tips.contains(where: { isDescendant($0.id, of: base) }) else { return nil }
        for name in options.hiddenReferences {
            var id = git_oid()
            guard git_reference_name_to_id(&id, pointer, name) == 0 else { continue }
            let hidden = (try? peeledCommit(OID(id))) ?? OID(id)
            if hidden == base || isDescendant(hidden, of: base) { return nil }
        }
        let baseTime = try commitTime(base)
        // Newest first, so the first that leads down to it is the one.
        for tip in tips where tip.id != base && tip.time >= baseTime {
            if try firstParents(of: tip.id, reach: base, notOlderThan: baseTime) {
                return tip.id
            }
        }
        return base
    }

    /// Whether following first parents down from `start` comes to `target`,
    /// giving up once the commits are older than `time` allows (a day of
    /// slack, for clocks that disagree).
    private func firstParents(of start: OID, reach target: OID, notOlderThan time: Int64) throws -> Bool {
        var next: OID? = start
        for _ in 0..<10_000 {
            guard let id = next else { return false }
            if id == target { return true }
            let commit = try lookupCommit(id)
            defer { git_commit_free(commit) }
            guard git_commit_time(commit) >= time - 86_400 else { return false }
            next = git_commit_parent_id(commit, 0).map { OID($0.pointee) }
        }
        return false
    }

    private func isDescendant(_ id: OID, of ancestor: OID) -> Bool {
        var commit = id.raw, base = ancestor.raw
        return git_graph_descendant_of(pointer, &commit, &base) == 1
    }

    private func commitTime(_ id: OID) throws -> Int64 {
        let commit = try lookupCommit(id)
        defer { git_commit_free(commit) }
        return git_commit_time(commit)
    }

    /// The commit an object leads to, through any tag objects.
    private func peeledCommit(_ id: OID) throws -> OID {
        var raw = id.raw
        var object: OpaquePointer?
        try check(git_object_lookup(&object, pointer, &raw, GIT_OBJECT_ANY))
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        try check(git_object_peel(&commit, object, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }
        return OID(git_object_id(commit))
    }
}
