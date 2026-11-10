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

/// Carries a stash search through libgit2's callback, which cannot capture Swift state.
private final class StashSearch {
    let id: OID
    var position: Int?

    init(id: OID) {
        self.id = id
    }
}
