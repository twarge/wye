import Clibgit2
import Foundation

/// How changes are set aside in a stash.
public struct StashOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Stash untracked files too, removing them from the working copy.
    public static let includeUntracked = StashOptions(rawValue: GIT_STASH_INCLUDE_UNTRACKED.rawValue)
    /// Leave the staged changes in place after stashing them.
    public static let keepIndex = StashOptions(rawValue: GIT_STASH_KEEP_INDEX.rawValue)
}

extension Repository {
    /// Sets the local changes aside in a new stash and returns its commit.
    /// Without a message, git's own "WIP on <branch>" is used.
    @discardableResult
    public func saveStash(message: String? = nil, options: StashOptions = []) throws -> OID {
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0 else {
            throw RepositoryError.identityNotConfigured
        }
        defer { git_signature_free(signature) }

        try reloadIndex()
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        var id = git_oid()
        let code = git_stash_save(&id, pointer, signature, message?.isEmpty == false ? message : nil, options.rawValue)
        if code == GIT_ENOTFOUND.rawValue { throw WorkingCopyError.nothingToStash }
        try check(code)
        return OID(id)
    }

    /// Applies a stash's changes to the working copy and keeps the stash.
    ///
    /// - Parameter restoringIndex: Whether changes that were staged when the
    ///   stash was made are staged again, rather than left unstaged.
    public func applyStash(_ stash: Stash, restoringIndex: Bool = false) throws {
        let position = try currentPosition(of: stash)
        var options = try applyOptions(restoringIndex: restoringIndex)
        try reloadIndex()
        try checkApply(git_stash_apply(pointer, position, &options))
    }

    /// Applies a stash's changes, then drops it. A stash that does not apply
    /// cleanly is kept.
    public func popStash(_ stash: Stash, restoringIndex: Bool = false) throws {
        let position = try currentPosition(of: stash)
        var options = try applyOptions(restoringIndex: restoringIndex)
        try reloadIndex()
        try checkApply(git_stash_pop(pointer, position, &options))
    }

    /// Deletes a stash. Its changes cannot be recovered from the list afterwards.
    public func dropStash(_ stash: Stash) throws {
        try check(git_stash_drop(pointer, try currentPosition(of: stash)))
    }

    // MARK: Snapshots

    /// Saves the local changes, untracked files among them, in a stash
    /// marked as a snapshot, and puts them straight back as they were,
    /// staged changes staged: the work stays in place and a copy that can
    /// be applied later is kept. Returns the snapshot's commit.
    @discardableResult
    public func saveSnapshot(message: String) throws -> OID {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
                .dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon))
        }
        let id = try saveStash(message: Stash.snapshotMarker + text, options: .includeUntracked)
        do {
            var options = try applyOptions(restoringIndex: true)
            try checkApply(git_stash_apply(pointer, 0, &options))
        } catch {
            throw SnapshotError.notRestored(reason: error.localizedDescription)
        }
        return id
    }

    // MARK: Branching from a stash

    /// Makes a branch at the commit a stash was made on, checks it out and
    /// applies the stash there, staged changes staged, then drops the stash,
    /// as `git stash branch` does. A stash that does not apply is kept.
    /// Returns the branch's full reference name.
    @discardableResult
    public func createBranch(fromStash stash: Stash, named name: String) throws -> String {
        let commit = try lookupCommit(stash.id)
        defer { git_commit_free(commit) }
        guard let base = git_commit_parent_id(commit, 0) else { throw WorkingCopyError.stashNotFound }
        let branch = try createBranch(named: name, at: OID(base))
        do {
            try checkOut(branch: branch)
        } catch {
            // As git's `checkout -b`, a checkout that fails makes no branch.
            try? deleteBranch(branch, force: true)
            throw error
        }
        try applyStash(stash, restoringIndex: true)
        try dropStash(stash)
        return branch
    }

    // MARK: A stash as a patch

    /// The changes a stash holds to tracked files, as the patch
    /// `git stash show -p` prints: from the commit it was made on to its
    /// working tree. Its untracked files are not in it, as in git's.
    public func patch(ofStash stash: Stash) throws -> String {
        let commit = try lookupCommit(stash.id)
        defer { git_commit_free(commit) }
        var parent: OpaquePointer?
        try check(git_commit_parent(&parent, commit, 0))
        defer { git_commit_free(parent) }
        let newTree = try tree(of: commit)
        defer { git_tree_free(newTree) }
        let oldTree = try tree(of: parent)
        defer { git_tree_free(oldTree) }
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags = GIT_DIFF_SHOW_BINARY.rawValue
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, pointer, oldTree, newTree, &options))
        defer { git_diff_free(diff) }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try check(git_diff_to_buf(&buffer, diff, GIT_DIFF_FORMAT_PATCH))
        return buffer.ptr.map { String(cString: $0) } ?? ""
    }

    /// Where a stash is in the list now. Positions shift as stashes are made
    /// and dropped, so the stash is found by its commit, not by the position
    /// it had when the list was read.
    private func currentPosition(of stash: Stash) throws -> Int {
        let found = StashSearch(id: stash.id)
        let code = git_stash_foreach(pointer, { index, _, id, payload in
            guard let id, let payload else { return 0 }
            let search = Unmanaged<StashSearch>.fromOpaque(payload).takeUnretainedValue()
            guard OID(id) == search.id else { return 0 }
            search.position = index
            return 1
        }, Unmanaged.passUnretained(found).toOpaque())
        if code < 0 { try check(code) }
        guard let position = found.position else { throw WorkingCopyError.stashNotFound }
        return position
    }

    /// libgit2 keeps the index in memory; another git may have changed it
    /// on disk since, and stashing must start from what is there now.
    private func reloadIndex() throws {
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))
    }

    private func applyOptions(restoringIndex: Bool) throws -> git_stash_apply_options {
        var options = git_stash_apply_options()
        try check(git_stash_apply_options_init(&options, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION)))
        if restoringIndex {
            options.flags = GIT_STASH_APPLY_REINSTATE_INDEX.rawValue
        }
        return options
    }

    private func checkApply(_ code: Int32) throws {
        if code == GIT_EMERGECONFLICT.rawValue || code == GIT_ECONFLICT.rawValue {
            throw WorkingCopyError.stashConflictsWithChanges
        }
        if code == GIT_ENOTFOUND.rawValue { throw WorkingCopyError.stashNotFound }
        try check(code)
    }
}

extension Stash {
    /// What a snapshot's message starts with, after git's "On <branch>: ".
    public static let snapshotMarker = "Snapshot: "

    /// Whether Twig made this stash as a snapshot: a copy of changes that
    /// were left in place.
    public var isSnapshot: Bool {
        subject.hasPrefix(Self.snapshotMarker)
    }

    /// The message without git's "On <branch>: " or "WIP on <branch>: ",
    /// and without the snapshot marker. Branch names cannot hold a colon,
    /// so the first ": " ends git's part.
    public var title: String {
        let text = subject
        return text.hasPrefix(Self.snapshotMarker) ? String(text.dropFirst(Self.snapshotMarker.count)) : text
    }

    private var subject: String {
        for prefix in ["On ", "WIP on "] where message.hasPrefix(prefix) {
            if let colon = message.range(of: ": ") {
                return String(message[colon.upperBound...])
            }
        }
        return message
    }
}

/// A snapshot that was saved but could not be put back in place.
public enum SnapshotError: Error, Hashable, Sendable, LocalizedError {
    case notRestored(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notRestored(let reason):
            "The snapshot was saved, but the changes could not be put back: \(reason) "
                + "They are safe in the snapshot; apply it from the stashes to get them back."
        }
    }
}

/// Carries a stash search through libgit2's callback, which cannot capture Swift state.
private final class StashSearch {
    let id: OID
    var position: Int?

    init(id: OID) {
        self.id = id
    }
}
