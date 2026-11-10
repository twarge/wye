import Clibgit2
import Foundation

/// An error reported by libgit2.
public struct GitError: Error, Hashable, Sendable, LocalizedError {
    /// libgit2's return code, a `git_error_code` value.
    public let code: Int32
    public let message: String

    public var errorDescription: String? { message }

    public var isNotFound: Bool { code == GIT_ENOTFOUND.rawValue }

    /// Captures libgit2's error for the calling thread. Call it straight after
    /// the failing function, before anything else can overwrite it.
    static func last(code: Int32) -> GitError {
        let message = git_error_last()?.pointee.message.map { String(cString: $0) }
        return GitError(code: code, message: message ?? "libgit2 error \(code)")
    }
}

/// A failure that is about the state of the repository, not a libgit2 call.
public enum RepositoryError: Error, Hashable, Sendable, LocalizedError {
    case identityNotConfigured
    case noWorkingDirectory
    case nothingToCommit
    case operationInProgress(RepositoryState)

    public var errorDescription: String? {
        switch self {
        case .identityNotConfigured:
            "No author name and email are set. Add them in Settings before committing."
        case .noWorkingDirectory:
            "This repository is bare: it has no working copy."
        case .nothingToCommit:
            "There are no staged changes to commit."
        case .operationInProgress:
            "Another operation is under way. Use Continue to carry on with it, or Abort to drop it."
        }
    }
}

/// Throws the calling thread's libgit2 error when `code` signals failure.
@discardableResult
func check(_ code: Int32) throws -> Int32 {
    guard code >= 0 else { throw GitError.last(code: code) }
    return code
}
