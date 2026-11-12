import Clibgit2
import Foundation

/// The state libgit2's remote callbacks need during one network operation.
///
/// C callbacks cannot capture Swift values, so the callbacks are plain
/// functions and this object travels to them through the payload pointer.
/// The caller keeps it alive for the length of the libgit2 call.
final class RemoteSession {
    let transfer: Transfer?
    let credentials: (any CredentialProvider)?

    /// Why the operation failed, when the reason is better than libgit2's.
    var failure: RemoteError?
    /// Remote references a push was refused for, with the remote's reason.
    var rejections: [(reference: String, reason: String)] = []
    /// For a force push: where each remote reference must still be, by full
    /// name, for the push to go ahead. A missing value means it must not exist.
    var leases: [String: OID?] = [:]
    /// Tags being pushed, by full name, with what they point at here. git
    /// refuses to move a tag the remote already has somewhere else, but
    /// libgit2 leaves that check to the caller.
    var protectedTags: [String: OID] = [:]
    /// Set when tags go along with a branch: instead of stopping at the
    /// first protected tag the remote has elsewhere, the negotiation notes
    /// every one in `tagConflicts` before stopping, so the push can go again
    /// without them.
    var collectsTagConflicts = false
    /// Protected tags the remote has at another object, by full name.
    var tagConflicts: [String] = []
    /// Protected tags the push changes on the remote: those it did not have.
    var tagUpdates: Set<String> = []

    private var credentialAttempts = 0
    private var lastReport = ContinuousClock.now
    private var lastPhase: TransferProgress.Phase?

    /// The all-zero name libgit2 uses for "no object".
    static let noObject = OID(git_oid())

    init(transfer: Transfer?, credentials: (any CredentialProvider)?) {
        self.transfer = transfer
        self.credentials = credentials
    }

    var isCancelled: Bool {
        transfer?.isCancelled == true || Task.isCancelled
    }

    /// Readies the session for the next remote of a multi-remote fetch.
    func resetForNextRemote() {
        credentialAttempts = 0
        failure = nil
    }

    /// Throws for a failed libgit2 call, preferring cancellation and the
    /// session's own explanation to libgit2's message.
    func check(_ code: Int32) throws {
        guard code < 0 else { return }
        let error = GitError.last(code: code)
        if isCancelled { throw CancellationError() }
        if let failure { throw failure }
        throw error
    }

    var payload: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static func from(_ payload: UnsafeMutableRawPointer?) -> RemoteSession? {
        payload.map { Unmanaged<RemoteSession>.fromOpaque($0).takeUnretainedValue() }
    }

    // MARK: Progress

    /// Passes progress on, at most every 50 milliseconds unless the phase
    /// changes or it completes: libgit2 reports every object.
    func report(_ progress: TransferProgress) {
        guard let transfer else { return }
        let now = ContinuousClock.now
        let isFinal = progress.total > 0 && progress.completed >= progress.total
        guard progress.phase != lastPhase || isFinal || now - lastReport >= .milliseconds(50) else { return }
        lastPhase = progress.phase
        lastReport = now
        transfer.report(progress)
    }

    // MARK: Credentials

    fileprivate func credential(
        _ out: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
        url: String,
        username: String?,
        allowedTypes: UInt32
    ) -> Int32 {
        if isCancelled { return GIT_EUSER.rawValue }
        let host = URLComponents(string: url)?.host ?? url
        // SSH logs in by itself, in SSHTransport; this is for HTTPS.
        guard allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else {
            return GIT_PASSTHROUGH.rawValue
        }
        credentialAttempts += 1
        // Asked again: the remote refused what was given the first time.
        // Asking the provider again would only get the same answer.
        guard credentialAttempts == 1 else {
            failure = .credentialsRejected(host: host, username: username)
            return GIT_EAUTH.rawValue
        }
        let request = CredentialRequest(url: url, host: host, username: username)
        guard let credential = credentials?.credential(for: request) else {
            failure = .credentialsRequired(host: host, username: username)
            return GIT_EAUTH.rawValue
        }
        return git_credential_userpass_plaintext_new(out, credential.username, credential.token)
    }

    // MARK: Callbacks

    /// Callbacks for fetching and pushing, reporting to this session.
    func callbacks() -> git_remote_callbacks {
        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        callbacks.payload = payload

        callbacks.credentials = { out, url, username, allowedTypes, payload in
            guard let session = RemoteSession.from(payload), let url else { return GIT_PASSTHROUGH.rawValue }
            return session.credential(
                out, url: String(cString: url), username: username.map { String(cString: $0) },
                allowedTypes: allowedTypes
            )
        }

        callbacks.sideband_progress = { text, length, payload in
            guard let session = RemoteSession.from(payload) else { return 0 }
            if session.isCancelled { return GIT_EUSER.rawValue }
            // What the server says alongside the data: kept for whoever
            // started the operation to read afterwards.
            if let text, length > 0, let transfer = session.transfer {
                text.withMemoryRebound(to: UInt8.self, capacity: Int(length)) {
                    transfer.hear(UnsafeBufferPointer(start: $0, count: Int(length)))
                }
            }
            return 0
        }

        callbacks.transfer_progress = { stats, payload in
            guard let session = RemoteSession.from(payload), let stats = stats?.pointee else { return 0 }
            if session.isCancelled { return GIT_EUSER.rawValue }
            let isResolving = stats.received_objects == stats.total_objects && stats.total_deltas > 0
            session.report(TransferProgress(
                phase: isResolving ? .resolvingDeltas : .receivingObjects,
                completed: Int(isResolving ? stats.indexed_deltas : stats.received_objects),
                total: Int(isResolving ? stats.total_deltas : stats.total_objects),
                bytes: stats.received_bytes
            ))
            return 0
        }

        callbacks.pack_progress = { _, current, total, payload in
            guard let session = RemoteSession.from(payload) else { return 0 }
            if session.isCancelled { return GIT_EUSER.rawValue }
            session.report(TransferProgress(phase: .countingObjects, completed: Int(current), total: Int(total)))
            return 0
        }

        callbacks.push_transfer_progress = { current, total, bytes, payload in
            guard let session = RemoteSession.from(payload) else { return 0 }
            if session.isCancelled { return GIT_EUSER.rawValue }
            session.report(TransferProgress(
                phase: .sendingObjects, completed: Int(current), total: Int(total), bytes: bytes
            ))
            return 0
        }

        callbacks.push_update_reference = { reference, status, payload in
            // A status is the remote's reason for refusing that reference.
            guard let session = RemoteSession.from(payload), let reference, let status else { return 0 }
            session.rejections.append((String(cString: reference), String(cString: status)))
            return 0
        }

        callbacks.push_negotiation = { updates, count, payload in
            guard let session = RemoteSession.from(payload),
                  !session.leases.isEmpty || !session.protectedTags.isEmpty, let updates else { return 0 }
            session.tagConflicts = []
            session.tagUpdates = []
            for index in 0..<count {
                guard let update = updates[index]?.pointee,
                      let name = update.dst_refname.map({ String(cString: $0) }) else { continue }
                // `src` is where the remote's reference is now; zero if it does not exist.
                let current = OID(update.src)
                let actual: OID? = current == RemoteSession.noObject ? nil : current
                if let local = session.protectedTags[name] {
                    if let actual, actual != local {
                        guard session.collectsTagConflicts else {
                            session.failure = .tagExistsOnRemote(String(name.dropFirst("refs/tags/".count)))
                            return GIT_EUSER.rawValue
                        }
                        session.tagConflicts.append(name)
                    } else if actual == nil {
                        session.tagUpdates.insert(name)
                    }
                    continue
                }
                guard let expected = session.leases[name] else { continue }
                if actual != expected {
                    let branch = name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
                    session.failure = .remoteMoved(branch: branch)
                    return GIT_EUSER.rawValue
                }
            }
            // libgit2 cannot leave a reference out once negotiating, so stop;
            // the caller pushes again without these.
            if let first = session.tagConflicts.first {
                session.failure = .tagExistsOnRemote(String(first.dropFirst("refs/tags/".count)))
                return GIT_EUSER.rawValue
            }
            return 0
        }
        return callbacks
    }

    /// Checkout options that report a clone's checkout to this session.
    func checkoutOptions() throws -> git_checkout_options {
        var options = git_checkout_options()
        try GitKit.check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        options.progress_payload = payload
        options.progress_cb = { _, completed, total, payload in
            RemoteSession.from(payload)?.report(TransferProgress(
                phase: .checkingOut, completed: completed, total: total
            ))
        }
        return options
    }
}
