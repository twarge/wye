import Clibgit2
import Foundation

extension Repository {
    /// Fetches only the given refspecs from a remote, by name, or from a
    /// URL that is not one of the repository's remotes, such as a pull
    /// request's head on someone else's copy of the repository:
    /// `+refs/heads/topic:refs/remotes/mona/topic`, `+refs/pull/12/head:refs/…`.
    /// Fetches no tags.
    public func fetch(
        refspecs: [String],
        from remote: String,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws {
        defer { transfer?.finish() }
        let session = RemoteSession(transfer: transfer, credentials: credentials)
        var pointer: OpaquePointer?
        let lookup = git_remote_lookup(&pointer, self.pointer, remote)
        if lookup == GIT_ENOTFOUND.rawValue || lookup == GIT_EINVALIDSPEC.rawValue {
            guard Self.looksLikeURL(remote) else { throw RemoteError.remoteNotFound(remote) }
            try check(git_remote_create_anonymous(&pointer, self.pointer, remote))
        } else {
            try check(lookup)
        }
        defer { git_remote_free(pointer) }
        session.report(TransferProgress(phase: .connecting))

        var options = git_fetch_options()
        try check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)))
        options.callbacks = session.callbacks()
        options.prune = GIT_FETCH_NO_PRUNE
        options.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE
        let code = withStringArray(refspecs) { refspecs in
            withExtendedLifetime(session) {
                git_remote_fetch(pointer, &refspecs, &options, nil)
            }
        }
        try session.check(code)
    }

    /// The best common ancestor of two commits, as `git merge-base`.
    public func mergeBase(_ left: OID, _ right: OID) throws -> OID {
        var result = git_oid()
        var leftOID = left.raw, rightOID = right.raw
        try check(git_merge_base(&result, pointer, &leftOID, &rightOID))
        return OID(result)
    }

    /// Whether a commit is in the repository's object database.
    public func hasCommit(_ id: OID) -> Bool {
        guard let commit = try? lookupCommit(id) else { return false }
        git_commit_free(commit)
        return true
    }

    /// A URL or scp-like address has a `:`, which a remote's name cannot.
    static func looksLikeURL(_ value: String) -> Bool {
        value.contains(":")
    }
}
