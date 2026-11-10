import Foundation

/// A working copy operation that cannot go ahead in the repository's present state.
public enum WorkingCopyError: Error, Hashable, Sendable, LocalizedError {
    /// The diff a selection was made in no longer matches the repository.
    case diffChanged(path: String)
    /// None of the selected lines adds or removes anything.
    case nothingSelected
    /// There is no commit to amend yet.
    case nothingToAmend
    /// A merge, rebase or similar is under way, which an amend would lose.
    case operationUnderWay(RepositoryState)
    case nothingToStash
    /// The stash was dropped or moved since the list was read.
    case stashNotFound
    /// Applying the stash would overwrite local changes.
    case stashConflictsWithChanges
    /// The file has no conflict to resolve.
    case notConflicted(path: String)
    /// The file is conflicted, and has to be resolved rather than discarded.
    case conflicted(path: String)

    public var errorDescription: String? {
        switch self {
        case .diffChanged(let path):
            "“\(path)” changed since its diff was shown. Look at it again and repeat the change."
        case .nothingSelected:
            "Select one or more added or removed lines first."
        case .nothingToAmend:
            "There is no commit to amend yet."
        case .operationUnderWay:
            "The last commit cannot be amended while an operation is under way. Finish or abort it first."
        case .nothingToStash:
            "There are no local changes to stash."
        case .stashNotFound:
            "That stash no longer exists."
        case .stashConflictsWithChanges:
            "The stash changes files that have local changes. Commit or stash those first."
        case .notConflicted(let path):
            "“\(path)” has no conflict to resolve."
        case .conflicted(let path):
            "“\(path)” has a conflict. Resolve it instead of discarding it."
        }
    }
}
