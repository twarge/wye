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

/// What an SSH server is being logged in to as.
public struct SSHKeyRequest: Hashable, Sendable {
    public var host: String
    public var port: Int
    /// The name in the remote's address, or `git` when it gives none.
    public var username: String

    public init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
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
///
/// SSH remotes ask for keys instead, and for a judgement of the server's
/// host key, which fails the operation with
/// ``RemoteError/unknownHostKey(_:)`` or
/// ``RemoteError/hostKeyChanged(_:known:)`` unless it is trusted.
public protocol CredentialProvider: SSHHostKeyValidator {
    func credential(for request: CredentialRequest) -> Credential?
    /// The keys to offer an SSH server, in order. The server takes the
    /// first it accepts.
    func sshKeys(for request: SSHKeyRequest) -> [SSHPrivateKey]
}

extension CredentialProvider {
    public func sshKeys(for request: SSHKeyRequest) -> [SSHPrivateKey] { [] }
    public func trust(for hostKey: SSHHostKey) -> SSHHostKeyTrust { .unknown }
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

    /// For tests: called with each report on the operation's own thread,
    /// before the report is passed on, so a test can act at an exact point.
    /// Set it before the operation starts.
    nonisolated(unsafe) var willReport: ((TransferProgress) -> Void)?

    func report(_ progress: TransferProgress) {
        willReport?(progress)
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
    /// The SSH server's host key is not among the known hosts.
    case unknownHostKey(SSHHostKey)
    /// The SSH server presented a different key from the one known for it.
    case hostKeyChanged(SSHHostKey, known: SSHPublicKey)
    /// There is no SSH key to log in with.
    case sshKeyRequired(host: String, username: String)
    /// The SSH server refused every key offered.
    case sshKeysRejected(host: String, username: String)
    /// The SSH server does not take keys at all.
    case sshKeysNotAccepted(host: String)
    /// Connecting to the SSH server, or its handshake, failed.
    case sshConnectionFailed(host: String, reason: String)
    /// The git command on the SSH server failed; what it said.
    case remoteCommandFailed(host: String, message: String)
    case invalidSSHAddress(String)
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
    /// A fast-forward-only pull found commits on both sides.
    case cannotFastForward(branch: String, onto: String)
    /// The remote branch was deleted on the remote; the fetch removed it here.
    case remoteBranchGone(String)
    /// The remote has a tag of that name on another commit.
    case tagExistsOnRemote(String)

    public var errorDescription: String? {
        switch self {
        case .credentialsRequired(let host, _):
            "\(host) asked for a username and access token."
        case .credentialsRejected(let host, _):
            "\(host) did not accept the username and access token."
        case .unknownHostKey(let key):
            "The authenticity of \(key.host) can’t be established. Its \(key.publicKey.displayName) key has the fingerprint \(key.fingerprint)."
        case .hostKeyChanged(let key, _):
            "The host key of \(key.host) has changed. It may have been replaced, or someone may be intercepting the connection. Its \(key.publicKey.displayName) key now has the fingerprint \(key.fingerprint)."
        case .sshKeyRequired(let host, _):
            "\(host) wants an SSH key, and Twig has none. Create or import one in Settings, then add its public key to your account on \(host)."
        case .sshKeysRejected(let host, let username):
            "\(host) did not accept Twig’s SSH keys for “\(username)”. Add your public key to your account on \(host)."
        case .sshKeysNotAccepted(let host):
            "\(host) does not accept SSH keys for logging in, and Twig has no other way."
        case .sshConnectionFailed(let host, let reason):
            "Could not connect to \(host) over SSH. \(reason)"
        case .remoteCommandFailed(let host, let message):
            "\(host) said: \(message)"
        case .invalidSSHAddress(let url):
            "“\(url)” is not an SSH address Twig can read."
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
        case .cannotFastForward(let branch, let onto):
            "“\(branch)” and “\(onto)” both have commits of their own, so “\(branch)” can’t simply move forward. Pull by merging or rebasing instead."
        case .remoteBranchGone(let name):
            "“\(name)” no longer exists on the remote."
        case .tagExistsOnRemote(let name):
            "The remote already has a tag “\(name)” on another commit. Delete it on the remote first to move it."
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
    /// The branch's own commits were replayed on top of this commit, the
    /// one pulled.
    case rebased(onto: OID)
    /// The rebase stopped on conflicts while replaying `commit`. The
    /// repository is left rebasing, to continue, skip or abort.
    case rebaseStopped(at: OID, conflicts: [String])

    /// Whether the pull stopped part way, leaving conflicts to resolve.
    public var stoppedOnConflicts: Bool {
        switch self {
        case .conflicts, .rebaseStopped: true
        case .upToDate, .fastForwarded, .merged, .rebased: false
        }
    }
}

/// How a pull brings the current branch up to the one it pulls.
public enum PullMode: String, Hashable, Sendable, CaseIterable {
    /// Fast-forward when possible, otherwise make a merge commit.
    case merge
    /// Fast-forward when possible, otherwise replay the branch's own commits
    /// on top of the pulled ones.
    case rebase
    /// Only fast-forward; refuse when both sides have commits.
    case fastForwardOnly
}

/// Which tags a fetch brings.
public enum FetchTags: Hashable, Sendable, CaseIterable {
    /// As the remote's `tagOpt` configuration says, as git does. Without
    /// one, libgit2 brings the remote's tags: unlike git, also those on
    /// commits that no fetched branch holds.
    case automatic
    /// Every tag on the remote, as `git fetch --tags`.
    case all
    /// No tags, as `git fetch --no-tags`.
    case none
}

/// How to pull.
public struct PullOptions: Hashable, Sendable {
    /// `nil` follows the repository's `pull.rebase` and `pull.ff`, merging
    /// when they say nothing.
    public var mode: PullMode?
    /// Set local changes aside in a stash first and restore them after.
    public var autostash: Bool

    public init(mode: PullMode? = nil, autostash: Bool = false) {
        self.mode = mode
        self.autostash = autostash
    }
}

/// What a pull did, and what became of the local changes it set aside.
public struct PullOutcome: Hashable, Sendable {
    public var result: PullResult
    public var autostash: AutostashResult

    public init(result: PullResult, autostash: AutostashResult) {
        self.result = result
        self.autostash = autostash
    }
}

/// What a sync did: the pull, then the push, which is left out when the
/// pull stopped on conflicts.
public struct SyncResult: Hashable, Sendable {
    public var pull: PullOutcome
    public var push: PushResult?
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
