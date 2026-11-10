import Clibgit2
import Foundation

/// What became of local changes that were set aside around an operation.
public enum AutostashResult: Hashable, Sendable {
    /// There were no changes to tracked files, so nothing was stashed.
    case notNeeded
    /// The changes were put back and the stash dropped.
    case restored
    /// Putting the changes back conflicted with what the operation did. The
    /// conflicts are in the working copy, and the stash is kept, as git
    /// keeps it, in case the resolution goes wrong.
    case conflicted(stash: OID, paths: [String])
    /// The changes could not be put back at all (untracked files are in the
    /// way, say). The working copy is as the operation left it; the changes
    /// wait in the stash.
    case notApplied(stash: OID)
    /// The operation stopped part way, on conflicts, so the changes wait in
    /// the stash until it is finished.
    case keptForLater(stash: OID)

    /// The stash still holding the changes, if one does.
    public var keptStash: OID? {
        switch self {
        case .notNeeded, .restored: nil
        case .conflicted(let stash, _), .notApplied(let stash), .keptForLater(let stash): stash
        }
    }
}

/// An operation's own result, with what became of the stashed changes.
public struct Autostashed<Value: Sendable>: Sendable {
    public var value: Value
    public var autostash: AutostashResult
}

/// An operation failed, and the changes stashed before it could not be put back.
public struct AutostashError: Error, Hashable, Sendable, LocalizedError {
    public let stash: OID
    /// Why the operation itself failed.
    public let reason: String

    public var errorDescription: String? {
        "\(reason) Your local changes were set aside in a stash first and could not be put back; they are kept in the stash."
    }
}

extension GitError {
    /// Whether local changes stopped the operation: a checkout that would
    /// overwrite them, or a rebase that needs a clean working copy.
    public var isBlockedByLocalChanges: Bool {
        code == GIT_ECONFLICT.rawValue || code == GIT_EUNCOMMITTED.rawValue || code == GIT_EMERGECONFLICT.rawValue
    }
}

extension Repository {
    /// Whether any tracked file has changes, staged or not: the changes an
    /// autostash sets aside. Untracked files are left where they are, as git
    /// leaves them.
    public func hasChangesToTrackedFiles() throws -> Bool {
        try status().contains { entry in
            entry.staged != nil || (entry.unstaged != nil && entry.unstaged != .untracked)
        }
    }

    /// Runs `body` with the local changes to tracked files set aside in a
    /// stash, then puts them back, as git's `--autostash` does.
    ///
    /// - When there is nothing to set aside, `body` simply runs.
    /// - When `body` leaves an operation stopped part way, the changes stay
    ///   in the stash for later, since putting them back would mix them with
    ///   the conflicts.
    /// - When putting them back conflicts, the conflicts are left to resolve
    ///   and the stash is kept.
    /// - When `body` throws, the changes are put back before the error is
    ///   passed on.
    public func withAutostash<Value: Sendable>(
        message: String = "autostash",
        _ body: @Sendable (isolated Repository) throws -> Value
    ) throws -> Autostashed<Value> {
        // Another operation under way refuses on its own; stashing first
        // would only get in its way.
        guard RepositoryState(git_repository_state(pointer)) == .clean, try hasChangesToTrackedFiles() else {
            return Autostashed(value: try body(self), autostash: .notNeeded)
        }
        let stash = try saveStash(message: message)
        let value: Value
        do {
            value = try body(self)
        } catch {
            let restored = (try? restoreAutostash(stash)) ?? .notApplied(stash: stash)
            guard restored == .restored else {
                throw AutostashError(stash: stash, reason: error.localizedDescription)
            }
            throw error
        }
        let isStopped = try RepositoryState(git_repository_state(pointer)) != .clean || !conflictedPaths().isEmpty
        if isStopped {
            return Autostashed(value: value, autostash: .keptForLater(stash: stash))
        }
        return Autostashed(value: value, autostash: try restoreAutostash(stash))
    }

    /// Puts an autostash back: staged changes staged again where that goes
    /// cleanly, otherwise everything as unstaged changes, as git does.
    private func restoreAutostash(_ id: OID) throws -> AutostashResult {
        let stash = Stash(id: id, index: 0, message: "", date: .now)
        do {
            try applyStash(stash, restoringIndex: true)
        } catch WorkingCopyError.stashConflictsWithChanges {
            do {
                // Restoring the index refuses before it changes anything.
                try applyStash(stash, restoringIndex: false)
            } catch WorkingCopyError.stashConflictsWithChanges {
                return .notApplied(stash: id)
            }
        }
        let conflicts = try conflictedPaths()
        guard conflicts.isEmpty else { return .conflicted(stash: id, paths: conflicts) }
        try dropStash(stash)
        return .restored
    }
}
