import Foundation
import Synchronization

/// A username and secret for an HTTPS remote. For the hosting services the
/// secret is a personal access token, not the account's password.
public struct Credential: Hashable, Sendable {
    public var username: String
    public var token: String

    public init(username: String, token: String) {
        self.username = username
        self.token = token
    }
}

/// What a remote asked for when it wanted credentials.
public struct CredentialRequest: Hashable, Sendable {
    /// The URL being fetched from or pushed to.
    public var url: String
    /// The host credentials are kept for, such as `github.com`.
    public var host: String
    /// The username written in the URL, if there is one.
    public var username: String?

    public init(url: String, host: String, username: String?) {
        self.url = url
        self.host = host
        self.username = username
    }
}

/// Supplies credentials when a remote asks for them.
///
/// libgit2 asks in the middle of a network operation, on the repository's
/// thread, so the answer must come straight away: from storage, never from a
/// prompt. When there is no answer, or the answer is refused, the operation
/// fails with ``RemoteError/credentialsRequired(host:username:)`` or
/// ``RemoteError/credentialsRejected(host:username:)``; the caller can then
/// ask the user and run it again. That keeps GitKit free of any knowledge of
/// where secrets are kept.
public protocol CredentialProvider: Sendable {
    func credential(for request: CredentialRequest) -> Credential?
}

/// How far a network operation has got.
public struct TransferProgress: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        /// Connecting and agreeing what to send; no counts yet.
        case connecting
        case receivingObjects
        case resolvingDeltas
        /// Working out which objects a push sends.
        case countingObjects
        case sendingObjects
        /// Writing the files of a fresh clone.
        case checkingOut
    }

    public var phase: Phase
    public var completed: Int
    public var total: Int
    /// Bytes received or sent so far.
    public var bytes: Int

    public init(phase: Phase, completed: Int = 0, total: Int = 0, bytes: Int = 0) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.bytes = bytes
    }

    /// From 0 to 1, or `nil` while the total is not known.
    public var fractionCompleted: Double? {
        total > 0 ? min(1, Double(completed) / Double(total)) : nil
    }
}

/// Follows and cancels one network operation.
///
/// Create one, pass it to the operation, and read ``progress`` from another
/// task. ``cancel()`` stops the operation at the next progress report; it then
/// throws `CancellationError`. Cancelling the task that runs the operation has
/// the same effect.
public final class Transfer: Sendable {
    /// Reports, most recent first if they arrive faster than they are read.
    /// Finishes when the operation does.
    public let progress: AsyncStream<TransferProgress>

    private let continuation: AsyncStream<TransferProgress>.Continuation
    private let cancelled = Atomic<Bool>(false)

    public init() {
        (progress, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    public var isCancelled: Bool {
        cancelled.load(ordering: .relaxed)
    }

    func report(_ progress: TransferProgress) {
        continuation.yield(progress)
    }

    func finish() {
        continuation.finish()
    }
}

/// A network operation's failure that is about the remote, not a libgit2 call.
public enum RemoteError: Error, Hashable, Sendable, LocalizedError {
    /// The remote wants credentials and the provider had none.
    case credentialsRequired(host: String, username: String?)
    /// The remote refused the credentials the provider gave.
    case credentialsRejected(host: String, username: String?)
    /// SSH needs libssh2, which this build of libgit2 does not include.
    case sshNotSupported(url: String)
    case noRemotes
    case remoteNotFound(String)
    /// `HEAD` is not on a branch, so there is nothing to push or pull.
    case notOnBranch
    /// The current branch has no upstream to pull from.
    case noUpstream(branch: String)
    /// The remote has commits the local branch does not.
    case nonFastForward(branch: String)
    /// A force push found the remote branch somewhere other than where the
    /// last fetch left it.
    case remoteMoved(branch: String)
    /// The remote turned the push down.
    case pushRejected(reference: String, reason: String)
    case invalidRemoteName(String)

    public var errorDescription: String? {
        switch self {
        case .credentialsRequired(let host, _):
            "\(host) asked for a username and access token."
        case .credentialsRejected(let host, _):
            "\(host) did not accept the username and access token."
        case .sshNotSupported(let url):
            "Twig can’t use SSH remotes yet. Use the remote’s HTTPS address instead of \(url)."
        case .noRemotes:
            "This repository has no remotes."
        case .remoteNotFound(let name):
            "There is no remote named “\(name)”."
        case .notOnBranch:
            "HEAD is not on a branch. Check out a branch first."
        case .noUpstream(let branch):
            "“\(branch)” has no upstream branch to pull from. Push it first to publish it."
        case .nonFastForward(let branch):
            "The remote’s “\(branch)” has commits that aren’t here. Pull, then push again."
        case .remoteMoved(let branch):
            "The remote’s “\(branch)” changed since the last fetch. Fetch and look at the new commits before forcing a push."
        case .pushRejected(let reference, let reason):
            "The remote rejected \(reference): \(reason)"
        case .invalidRemoteName(let name):
            "“\(name)” is not a valid remote name."
        }
    }

    /// The host whose credentials should be asked for, for the two
    /// credential failures.
    public var credentialHost: (host: String, username: String?)? {
        switch self {
        case .credentialsRequired(let host, let username), .credentialsRejected(let host, let username):
            (host, username)
        default:
            nil
        }
    }
}

/// What a pull did.
public enum PullResult: Hashable, Sendable {
    case upToDate
    /// The branch moved forward to the upstream's commit.
    case fastForwarded(to: OID)
    /// The upstream's commits were merged in a new commit.
    case merged(commit: OID)
    /// The merge stopped on conflicts. The repository is left merging, with
    /// the conflicts in the working copy, for the user to resolve and commit.
    case conflicts(paths: [String])
}

/// What a push did.
public struct PushResult: Hashable, Sendable {
    public var remote: String
    /// The reference updated on the remote, such as `refs/heads/main`.
    public var reference: String
    /// Whether this push made the remote branch the local one's upstream.
    public var setUpstream: Bool

    public init(remote: String, reference: String, setUpstream: Bool) {
        self.remote = remote
        self.reference = reference
        self.setUpstream = setUpstream
    }
}
