import Clibgit2
import Foundation

/// What merging, rebasing or applying commits would do, worked out in memory
/// without touching the working tree, the index or any reference.
public struct MergePreview: Hashable, Sendable {
    public enum Verdict: Hashable, Sendable {
        /// Nothing to do: the current branch already has it all.
        case upToDate
        /// The current branch has nothing of its own, so it can simply move.
        case fastForward
        /// A merge, or every replayed commit, would go through without conflicts.
        case clean
        /// These files would conflict. For a rebase or a run of commits, at
        /// the first commit that stops; later ones depend on how it is resolved.
        case conflicts([String])
    }

    public let verdict: Verdict
    /// How many commits a rebase or cherry-pick would replay. One for a merge.
    public let commitCount: Int
    /// The commit that would stop with conflicts, in a rebase or a run of commits.
    public let stoppingCommit: OID?
    /// Which commit, from 1, of `commitCount` would stop.
    public let stoppingStep: Int?

    public init(_ verdict: Verdict, commitCount: Int = 1, stoppingCommit: OID? = nil, stoppingStep: Int? = nil) {
        self.verdict = verdict
        self.commitCount = commitCount
        self.stoppingCommit = stoppingCommit
        self.stoppingStep = stoppingStep
    }
}

extension Repository {
    // These run off the actor, on a repository handle of their own, so a long
    // preview does not hold up anything else and can be cancelled between
    // steps. The merges write their results only as loose objects, which
    // nothing refers to.

    /// What merging a branch, remote branch or tag, by full reference name,
    /// or any other revision into `HEAD` would do.
    @concurrent public nonisolated func previewMerge(of revision: String) async throws -> MergePreview {
        try Task.checkCancellation()
        let preview = try PreviewRepository(url)
        let theirs = try preview.commit(revision)
        defer { git_commit_free(theirs) }
        guard let ours = try preview.headCommit() else { return MergePreview(.fastForward) }
        defer { git_commit_free(ours) }
        if let verdict = try preview.ancestry(ours: ours, theirs: theirs) { return MergePreview(verdict) }

        try Task.checkCancellation()
        var options = try PreviewRepository.mergeOptions()
        var index: OpaquePointer?
        try check(git_merge_commits(&index, preview.pointer, ours, theirs, &options))
        defer { git_index_free(index) }
        let conflicts = try PreviewRepository.conflicts(in: index)
        return MergePreview(conflicts.isEmpty ? .clean : .conflicts(conflicts))
    }

    /// What rebasing the current branch onto a revision would do: each of
    /// its own commits, merges left out, replayed in turn as libgit2's rebase
    /// replays them.
    @concurrent public nonisolated func previewRebase(onto revision: String) async throws -> MergePreview {
        try Task.checkCancellation()
        let preview = try PreviewRepository(url)
        let upstream = try preview.commit(revision)
        defer { git_commit_free(upstream) }
        guard let head = try preview.headCommit() else {
            throw GitError(code: GIT_EUNBORNBRANCH.rawValue, message: "There is no commit to rebase yet.")
        }
        defer { git_commit_free(head) }
        if let verdict = try preview.ancestry(ours: head, theirs: upstream) {
            // Here "ours" is what is replayed: when upstream already has it, a
            // rebase moves the branch, and when it has upstream, nothing changes.
            return MergePreview(verdict == .fastForward ? .fastForward : .upToDate, commitCount: 0)
        }

        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, preview.pointer))
        defer { git_revwalk_free(walk) }
        try check(git_revwalk_push(walk, git_commit_id(head)))
        try check(git_revwalk_hide(walk, git_commit_id(upstream)))
        try check(git_revwalk_sorting(walk, GIT_SORT_REVERSE.rawValue))
        var ids: [OID] = []
        var next = git_oid()
        while git_revwalk_next(&next, walk) == 0 {
            let commit = try preview.lookup(OID(next))
            defer { git_commit_free(commit) }
            if git_commit_parentcount(commit) <= 1 { ids.append(OID(next)) }
        }
        return try preview.replay(ids.map { ($0, .pick) }, onto: upstream)
    }

    /// What cherry-picking commits, in the order given, onto `HEAD` would do.
    @concurrent public nonisolated func previewCherryPick(_ ids: [OID]) async throws -> MergePreview {
        try await previewSequence(ids.map { ($0, .pick) })
    }

    /// What reverting commits, in the order given, on `HEAD` would do.
    @concurrent public nonisolated func previewRevert(_ ids: [OID]) async throws -> MergePreview {
        try await previewSequence(ids.map { ($0, .revert) })
    }

    @concurrent private nonisolated func previewSequence(_ steps: [(OID, PreviewRepository.Step)]) async throws -> MergePreview {
        try Task.checkCancellation()
        let preview = try PreviewRepository(url)
        guard let head = try preview.headCommit() else {
            throw GitError(code: GIT_EUNBORNBRANCH.rawValue, message: "There is no commit to apply changes on yet.")
        }
        defer { git_commit_free(head) }
        return try preview.replay(steps, onto: head)
    }
}

/// A second handle on the repository, for previews to use on their own thread.
private final class PreviewRepository {
    enum Step { case pick, revert }

    let pointer: OpaquePointer

    init(_ url: URL) throws {
        GitEnvironment.ensureInitialized()
        var pointer: OpaquePointer?
        try check(git_repository_open_ext(&pointer, url.path, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil))
        self.pointer = pointer!
    }

    deinit {
        git_repository_free(pointer)
    }

    /// A full reference name or any other revision, as a commit. The caller frees it.
    func commit(_ revision: String) throws -> OpaquePointer {
        var object: OpaquePointer?
        if revision.hasPrefix("refs/") {
            var reference: OpaquePointer?
            try check(git_reference_lookup(&reference, pointer, revision))
            defer { git_reference_free(reference) }
            try check(git_reference_peel(&object, reference, GIT_OBJECT_COMMIT))
        } else {
            var found: OpaquePointer?
            try check(git_revparse_single(&found, pointer, revision))
            defer { git_object_free(found) }
            try check(git_object_peel(&object, found, GIT_OBJECT_COMMIT))
        }
        return object!
    }

    func lookup(_ id: OID) throws -> OpaquePointer {
        var oid = id.raw
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, pointer, &oid))
        return commit!
    }

    /// `HEAD`'s commit, or `nil` on a branch with none yet.
    func headCommit() throws -> OpaquePointer? {
        var reference: OpaquePointer?
        let code = git_repository_head(&reference, pointer)
        if code == GIT_EUNBORNBRANCH.rawValue || code == GIT_ENOTFOUND.rawValue { return nil }
        try check(code)
        defer { git_reference_free(reference) }
        var commit: OpaquePointer?
        try check(git_reference_peel(&commit, reference, GIT_OBJECT_COMMIT))
        return commit
    }

    /// Up to date when `ours` has `theirs`, a fast-forward when `theirs` has
    /// `ours`, and `nil` when each has commits of its own.
    func ancestry(ours: OpaquePointer, theirs: OpaquePointer) throws -> MergePreview.Verdict? {
        var base = git_oid()
        let code = git_merge_base(&base, pointer, git_commit_id(ours), git_commit_id(theirs))
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try check(code)
        if OID(base) == OID(git_commit_id(theirs)) { return .upToDate }
        if OID(base) == OID(git_commit_id(ours)) { return .fastForward }
        return nil
    }

    /// Applies each commit's changes in turn, as a cherry-pick or revert of
    /// it would, starting from `start`'s tree, stopping at the first conflict.
    func replay(_ steps: [(OID, Step)], onto start: OpaquePointer) throws -> MergePreview {
        var current: OpaquePointer?
        try check(git_commit_tree(&current, start))
        defer { git_tree_free(current) }

        for (position, (id, step)) in steps.enumerated() {
            try Task.checkCancellation()
            let commit = try lookup(id)
            defer { git_commit_free(commit) }
            var tree: OpaquePointer?
            try check(git_commit_tree(&tree, commit))
            defer { git_tree_free(tree) }
            // A merge commit is taken against its first parent, as the
            // cherry-pick and revert themselves do.
            var parentTree: OpaquePointer?
            if git_commit_parentcount(commit) > 0 {
                var parent: OpaquePointer?
                try check(git_commit_parent(&parent, commit, 0))
                defer { git_commit_free(parent) }
                try check(git_commit_tree(&parentTree, parent))
            }
            defer { git_tree_free(parentTree) }

            var options = try Self.mergeOptions()
            var index: OpaquePointer?
            let (ancestor, theirs) = step == .pick ? (parentTree, tree) : (tree, parentTree)
            try check(git_merge_trees(&index, pointer, ancestor, current, theirs, &options))
            defer { git_index_free(index) }
            let conflicts = try Self.conflicts(in: index)
            if !conflicts.isEmpty {
                return MergePreview(
                    .conflicts(conflicts), commitCount: steps.count, stoppingCommit: id, stoppingStep: position + 1
                )
            }
            var written = git_oid()
            try check(git_index_write_tree_to(&written, index, pointer))
            var next: OpaquePointer?
            try check(git_tree_lookup(&next, pointer, &written))
            git_tree_free(current)
            current = next
        }
        return MergePreview(.clean, commitCount: steps.count)
    }

    static func mergeOptions() throws -> git_merge_options {
        var options = git_merge_options()
        try check(git_merge_options_init(&options, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        return options
    }

    /// The conflicted paths in an index, in its order.
    static func conflicts(in index: OpaquePointer?) throws -> [String] {
        guard git_index_has_conflicts(index) != 0 else { return [] }
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index))
        defer { git_index_conflict_iterator_free(iterator) }
        var ancestor: UnsafePointer<git_index_entry>?
        var ours: UnsafePointer<git_index_entry>?
        var theirs: UnsafePointer<git_index_entry>?
        var paths: [String] = []
        while git_index_conflict_next(&ancestor, &ours, &theirs, iterator) == 0 {
            if let entry = ours ?? theirs ?? ancestor {
                paths.append(String(cString: entry.pointee.path))
            }
        }
        return paths
    }
}
