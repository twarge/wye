import Clibgit2
import Foundation

extension Repository {
    // MARK: Fetch

    /// Fetches from one remote, or from every remote when `remote` is `nil`,
    /// removing remote branches that are gone from the remote when `prune`
    /// is set.
    public func fetch(
        remote name: String? = nil,
        prune: Bool = true,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws {
        defer { transfer?.finish() }
        let names = try name.map { [$0] } ?? remoteNames()
        guard !names.isEmpty else { throw RemoteError.noRemotes }
        let session = RemoteSession(transfer: transfer, credentials: credentials)
        for name in names {
            session.resetForNextRemote()
            try fetch(name, prune: prune, session: session)
        }
    }

    private func fetch(_ name: String, prune: Bool, session: RemoteSession) throws {
        let remote = try lookupRemote(name)
        defer { git_remote_free(remote) }
        if let url = git_remote_url(remote).map({ String(cString: $0) }) {
            try Self.requireSupportedURL(url)
        }
        session.report(TransferProgress(phase: .connecting))

        var options = git_fetch_options()
        try check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)))
        options.callbacks = session.callbacks()
        options.prune = prune ? GIT_FETCH_PRUNE : GIT_FETCH_NO_PRUNE
        try withExtendedLifetime(session) {
            try session.check(git_remote_fetch(remote, nil, &options, nil))
        }
    }

    // MARK: Push

    /// Pushes the current branch to its upstream, or to the same branch name
    /// on `remote` when one is given. A branch without an upstream is
    /// published: pushed to `remote` (or `origin`, or the only remote) under
    /// its own name, and that remote branch becomes its upstream.
    ///
    /// A push that would drop commits on the remote is refused, unless
    /// `force` is set. Even then it is refused if the remote branch moved
    /// since it was last fetched, so that nobody's work is lost unseen.
    @discardableResult
    public func push(
        to remote: String? = nil,
        force: Bool = false,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws -> PushResult {
        defer { transfer?.finish() }
        guard case .branch(let branchReference, _) = try head() else { throw RemoteError.notOnBranch }
        let branchName = String(branchReference.dropFirst("refs/heads/".count))

        let upstream = upstreamConfiguration(of: branchReference)
        let remoteName = try remote ?? upstream?.remote ?? defaultRemoteName()
        // An upstream on another remote than the one asked for does not apply.
        let destination = upstream.flatMap { $0.remote == remoteName ? $0.merge : nil } ?? branchReference
        // Only a branch with no upstream at all gets one; pushing elsewhere
        // leaves an existing upstream alone.
        let publishes = upstream?.merge == nil

        let remotePointer = try lookupRemote(remoteName)
        defer { git_remote_free(remotePointer) }
        if let url = (git_remote_pushurl(remotePointer) ?? git_remote_url(remotePointer)).map({ String(cString: $0) }) {
            try Self.requireSupportedURL(url)
        }

        let session = RemoteSession(transfer: transfer, credentials: credentials)
        if force {
            session.leases[destination] = trackingTarget(of: destination, on: remoteName)
        }
        session.report(TransferProgress(phase: .connecting))

        var options = git_push_options()
        try check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)))
        options.callbacks = session.callbacks()
        let refspec = (force ? "+" : "") + "\(branchReference):\(destination)"
        let code = withStringArray([refspec]) { refspecs in
            withExtendedLifetime(session) {
                git_remote_push(remotePointer, &refspecs, &options)
            }
        }
        if code == GIT_ENONFASTFORWARD.rawValue {
            throw RemoteError.nonFastForward(branch: String(destination.dropFirst("refs/heads/".count)))
        }
        try session.check(code)
        if let rejection = session.rejections.first {
            throw RemoteError.pushRejected(reference: rejection.reference, reason: rejection.reason)
        }

        if publishes {
            try setUpstreamConfiguration(of: branchName, remote: remoteName, merge: destination)
        }
        return PushResult(remote: remoteName, reference: destination, setUpstream: publishes)
    }

    // MARK: Pull

    /// Fetches the current branch's upstream remote, then brings the branch
    /// up to its upstream: a fast-forward when possible, otherwise a merge.
    /// A merge that conflicts leaves the repository merging.
    public func pull(
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws -> PullResult {
        guard case .branch(let branchReference, _) = try head() else {
            transfer?.finish()
            throw RemoteError.notOnBranch
        }
        let branchName = String(branchReference.dropFirst("refs/heads/".count))
        guard let upstream = upstreamConfiguration(of: branchReference), upstream.merge != nil else {
            transfer?.finish()
            throw RemoteError.noUpstream(branch: branchName)
        }
        try fetch(remote: upstream.remote, prune: true, credentials: credentials, transfer: transfer)

        var branch: OpaquePointer?
        try check(git_reference_lookup(&branch, pointer, branchReference))
        defer { git_reference_free(branch) }
        var upstreamReference: OpaquePointer?
        let found = git_branch_upstream(&upstreamReference, branch)
        if found == GIT_ENOTFOUND.rawValue {
            // Configured, but the remote has no such branch.
            throw RemoteError.noUpstream(branch: branchName)
        }
        try check(found)
        defer { git_reference_free(upstreamReference) }

        var theirs: OpaquePointer?
        try check(git_annotated_commit_from_ref(&theirs, pointer, upstreamReference))
        defer { git_annotated_commit_free(theirs) }
        let theirID = OID(git_annotated_commit_id(theirs))

        var analysis = git_merge_analysis_t(rawValue: 0)
        var preference = git_merge_preference_t(rawValue: 0)
        var heads: [OpaquePointer?] = [theirs]
        try check(git_merge_analysis(&analysis, &preference, pointer, &heads, 1))

        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return .upToDate
        }
        if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0,
           preference.rawValue & GIT_MERGE_PREFERENCE_NO_FASTFORWARD.rawValue == 0 {
            try fastForward(branch, to: theirID)
            return .fastForwarded(to: theirID)
        }

        let upstreamName = String(cString: git_reference_shorthand(upstreamReference))
        let remoteURL = (try? remoteURL(of: upstream.remote)) ?? upstream.remote
        let theirBranch = upstream.merge.map { String($0.dropFirst("refs/heads/".count)) } ?? upstreamName
        return try mergeForPull(
            theirs, id: theirID, message: "Merge branch '\(theirBranch)' of \(remoteURL)"
        )
    }

    private func fastForward(_ branch: OpaquePointer?, to id: OID) throws {
        let commit = try lookupCommit(id)
        defer { git_commit_free(commit) }
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        // Fails, touching nothing, if a local change is in the way.
        try check(git_checkout_tree(pointer, commit, &options))
        var oid = id.raw
        var moved: OpaquePointer?
        try check(git_reference_set_target(&moved, branch, &oid, "pull: Fast-forward"))
        git_reference_free(moved)
    }

    /// Merges the fetched commit into `HEAD`, committing unless it conflicts.
    private func mergeForPull(_ theirs: OpaquePointer?, id: OID, message: String) throws -> PullResult {
        // Checked before merging, so a missing identity does not strand a
        // merge that cannot be committed.
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0 else {
            throw RepositoryError.identityNotConfigured
        }
        defer { git_signature_free(signature) }

        var mergeOptions = git_merge_options()
        try check(git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        var checkoutOptions = git_checkout_options()
        try check(git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        var heads: [OpaquePointer?] = [theirs]
        // On failure libgit2 removes the merge state it began.
        try check(git_merge(pointer, &heads, 1, &mergeOptions, &checkoutOptions))

        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) != 0 {
            return .conflicts(paths: try conflictedPaths(in: index))
        }

        var treeID = git_oid()
        try check(git_index_write_tree(&treeID, index))
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &treeID))
        defer { git_tree_free(tree) }
        let head = try headCommit()
        let their = try lookupCommit(id)
        var parents: [OpaquePointer?] = [head, their]
        defer { parents.forEach { git_commit_free($0) } }

        var commitID = git_oid()
        try check(git_commit_create(
            &commitID, pointer, "HEAD", signature, signature, nil, message + "\n", tree, parents.count, &parents
        ))
        try check(git_repository_state_cleanup(pointer))
        return .merged(commit: OID(commitID))
    }

    private func conflictedPaths(in index: OpaquePointer?) throws -> [String] {
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index))
        defer { git_index_conflict_iterator_free(iterator) }
        var paths: [String] = []
        var ancestor: UnsafePointer<git_index_entry>?
        var ours: UnsafePointer<git_index_entry>?
        var theirs: UnsafePointer<git_index_entry>?
        while git_index_conflict_next(&ancestor, &ours, &theirs, iterator) == 0 {
            if let path = (ours ?? theirs ?? ancestor)?.pointee.path {
                paths.append(String(cString: path))
            }
        }
        return paths
    }

    // MARK: Clone

    /// Clones the repository at `url` into `directory`, which must not exist
    /// or be empty, checks out the remote's default branch, and opens it.
    /// A failed or cancelled clone leaves no partial repository behind.
    @concurrent
    public static func clone(
        from url: String,
        to directory: URL,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) async throws -> Repository {
        GitEnvironment.ensureInitialized()
        defer { transfer?.finish() }
        try requireSupportedURL(url)
        let session = RemoteSession(transfer: transfer, credentials: credentials)
        // A clone from a local path copies files without reporting progress,
        // so cancellation is checked before it starts too.
        if session.isCancelled { throw CancellationError() }
        session.report(TransferProgress(phase: .connecting))

        var options = git_clone_options()
        try check(git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)))
        options.fetch_opts.callbacks = session.callbacks()
        options.checkout_opts = try session.checkoutOptions()
        var pointer: OpaquePointer?
        try withExtendedLifetime(session) {
            try session.check(git_clone(&pointer, url, directory.path, &options))
        }
        git_repository_free(pointer)
        return try Repository(at: directory)
    }

    // MARK: Remote management

    /// Adds a remote that fetches all of its branches.
    public func addRemote(named name: String, url: String) throws {
        try Self.requireValidRemoteName(name)
        var remote: OpaquePointer?
        try check(git_remote_create(&remote, pointer, name, url))
        git_remote_free(remote)
    }

    /// Renames a remote and its remote branches. Returns the fetch refspecs
    /// that were not the standard one and so could not be renamed.
    @discardableResult
    public func renameRemote(_ name: String, to newName: String) throws -> [String] {
        try Self.requireValidRemoteName(newName)
        var problems = git_strarray()
        try check(git_remote_rename(&problems, pointer, name, newName))
        defer { git_strarray_dispose(&problems) }
        return (0..<problems.count).compactMap { problems.strings[$0].map { String(cString: $0) } }
    }

    /// Removes a remote, its remote branches and its configuration.
    public func removeRemote(named name: String) throws {
        try check(git_remote_delete(pointer, name))
    }

    public func setURL(_ url: String, ofRemote name: String) throws {
        try check(git_remote_set_url(pointer, name, url))
    }

    // MARK: Helpers

    private func remoteNames() throws -> [String] {
        var names = git_strarray()
        try check(git_remote_list(&names, pointer))
        defer { git_strarray_dispose(&names) }
        return (0..<names.count).compactMap { names.strings[$0].map { String(cString: $0) } }
    }

    /// `origin` if there is one, otherwise the only remote.
    private func defaultRemoteName() throws -> String {
        let names = try remoteNames()
        if names.contains("origin") { return "origin" }
        guard let only = names.first else { throw RemoteError.noRemotes }
        guard names.count == 1 else {
            throw RemoteError.remoteNotFound("origin")
        }
        return only
    }

    private func lookupRemote(_ name: String) throws -> OpaquePointer? {
        var remote: OpaquePointer?
        let code = git_remote_lookup(&remote, pointer, name)
        if code == GIT_ENOTFOUND.rawValue { throw RemoteError.remoteNotFound(name) }
        try check(code)
        return remote
    }

    private func remoteURL(of name: String) throws -> String? {
        let remote = try lookupRemote(name)
        defer { git_remote_free(remote) }
        return git_remote_url(remote).map { String(cString: $0) }
    }

    /// `branch.<name>.remote` and `branch.<name>.merge`, read from the
    /// configuration directly: unlike libgit2's upstream lookup, this works
    /// before the remote branch has been fetched.
    private func upstreamConfiguration(of branchReference: String) -> (remote: String, merge: String?)? {
        var remoteBuffer = git_buf()
        defer { git_buf_dispose(&remoteBuffer) }
        guard git_branch_upstream_remote(&remoteBuffer, pointer, branchReference) == 0,
              let remote = remoteBuffer.ptr.map({ String(cString: $0) }), !remote.isEmpty else { return nil }
        var mergeBuffer = git_buf()
        defer { git_buf_dispose(&mergeBuffer) }
        let merge = git_branch_upstream_merge(&mergeBuffer, pointer, branchReference) == 0
            ? mergeBuffer.ptr.map { String(cString: $0) } : nil
        return (remote, merge)
    }

    private func setUpstreamConfiguration(of branchName: String, remote: String, merge: String) throws {
        var configuration: OpaquePointer?
        try check(git_repository_config(&configuration, pointer))
        defer { git_config_free(configuration) }
        try check(git_config_set_string(configuration, "branch.\(branchName).remote", remote))
        try check(git_config_set_string(configuration, "branch.\(branchName).merge", merge))
    }

    /// Where the last fetch saw `reference` on `remote`: the commit of the
    /// matching remote branch, or `nil` if there is none.
    private func trackingTarget(of reference: String, on remote: String) -> OID? {
        var remotePointer: OpaquePointer?
        guard git_remote_lookup(&remotePointer, pointer, remote) == 0 else { return nil }
        defer { git_remote_free(remotePointer) }
        var tracking = git_buf()
        defer { git_buf_dispose(&tracking) }
        // Each fetch refspec maps a remote reference to a local one; the
        // first that matches names the remote branch.
        for index in 0..<git_remote_refspec_count(remotePointer) {
            guard let refspec = git_remote_get_refspec(remotePointer, index),
                  git_refspec_direction(refspec) == GIT_DIRECTION_FETCH,
                  git_refspec_src_matches(refspec, reference) != 0,
                  git_refspec_transform(&tracking, refspec, reference) == 0,
                  let name = tracking.ptr else { continue }
            var oid = git_oid()
            guard git_reference_name_to_id(&oid, pointer, name) == 0 else { return nil }
            return OID(oid)
        }
        return nil
    }

    private static func requireValidRemoteName(_ name: String) throws {
        var valid: Int32 = 0
        try check(git_remote_name_is_valid(&valid, name))
        guard valid != 0 else { throw RemoteError.invalidRemoteName(name) }
    }

    /// Refuses SSH addresses up front, with a better message than libgit2's.
    /// HTTPS, plain HTTP, the git protocol and local paths all work.
    static func requireSupportedURL(_ url: String) throws {
        if let schemeEnd = url.range(of: "://") {
            let scheme = url[..<schemeEnd.lowerBound].lowercased()
            if scheme == "ssh" || scheme.hasPrefix("ssh+") || scheme.hasSuffix("+ssh") {
                throw RemoteError.sshNotSupported(url: url)
            }
        } else if let colon = url.firstIndex(of: ":"),
                  !url[..<colon].contains("/"), url[..<colon].count > 1 {
            // `user@host:path`, the short form of an SSH address. A single
            // letter before the colon would be a Windows drive.
            throw RemoteError.sshNotSupported(url: url)
        }
    }
}
