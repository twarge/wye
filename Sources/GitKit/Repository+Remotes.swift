import Clibgit2
import Foundation

extension Repository {
    // MARK: Fetch

    /// Fetches from one remote, or from every remote when `remote` is `nil`,
    /// removing remote branches that are gone from the remote when `prune`
    /// is set. `tags` says which tags come too.
    public func fetch(
        remote name: String? = nil,
        prune: Bool = true,
        tags: FetchTags = .automatic,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws {
        defer { transfer?.finish() }
        try fetchRemotes(name, prune: prune, tags: tags, session: RemoteSession(transfer: transfer, credentials: credentials))
    }

    /// Fetches without finishing the transfer, for operations that go on
    /// to do more under the same progress display.
    func fetchRemotes(_ name: String?, prune: Bool, tags: FetchTags, session: RemoteSession) throws {
        let names = try name.map { [$0] } ?? remoteNames()
        guard !names.isEmpty else { throw RemoteError.noRemotes }
        for name in names {
            session.resetForNextRemote()
            try fetch(name, prune: prune, tags: tags, session: session)
        }
    }

    private func fetch(_ name: String, prune: Bool, tags: FetchTags, session: RemoteSession) throws {
        let remote = try lookupRemote(name)
        defer { git_remote_free(remote) }
        if let url = git_remote_url(remote).map({ String(cString: $0) }) {
            try useResolvedURL(url, for: remote, push: false)
        }
        session.report(TransferProgress(phase: .connecting))

        var options = git_fetch_options()
        try check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)))
        options.callbacks = session.callbacks()
        options.prune = prune ? GIT_FETCH_PRUNE : GIT_FETCH_NO_PRUNE
        options.download_tags = switch tags {
        case .automatic: GIT_REMOTE_DOWNLOAD_TAGS_UNSPECIFIED
        case .all: GIT_REMOTE_DOWNLOAD_TAGS_ALL
        case .none: GIT_REMOTE_DOWNLOAD_TAGS_NONE
        }
        try withExtendedLifetime(session) {
            try session.check(git_remote_fetch(remote, nil, &options, nil))
        }

        // Following tags, the remote sends those on the commits it sends,
        // but not one made later on a commit fetched before. git fetches
        // those in a second round, and so does this.
        guard tags == .automatic, git_remote_autotag(remote) == GIT_REMOTE_DOWNLOAD_TAGS_AUTO else { return }
        let missing = try tagsOnCommitsHere(advertisedBy: remote)
        guard !missing.isEmpty else { return }
        session.resetForNextRemote()
        options.prune = GIT_FETCH_NO_PRUNE
        options.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE
        // `FETCH_HEAD` keeps the branches the first round fetched.
        options.update_fetchhead = 0
        let code = withStringArray(missing.map { "\($0):\($0)" }) { refspecs in
            withExtendedLifetime(session) {
                git_remote_fetch(remote, &refspecs, &options, nil)
            }
        }
        try session.check(code)
    }

    /// The tags, by full name, that the remote has on commits here but this
    /// repository lacks, from what the remote listed when it was last
    /// connected to. As when git follows tags, one of the same name here is
    /// left as it is.
    private func tagsOnCommitsHere(advertisedBy remote: OpaquePointer?) throws -> [String] {
        var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
        var count = 0
        try check(git_remote_ls(&heads, &count, remote))
        guard let heads, count > 0 else { return [] }
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, pointer))
        defer { git_odb_free(odb) }

        // An annotated tag is listed twice: its own object, then as
        // `name^{}`, the commit it is on.
        var tags: [(name: String, id: git_oid)] = []
        var peeled: [String: git_oid] = [:]
        for head in UnsafeBufferPointer(start: heads, count: count) {
            guard let head = head?.pointee, let name = head.name.map({ String(cString: $0) }),
                  name.hasPrefix("refs/tags/") else { continue }
            if name.hasSuffix("^{}") {
                peeled[String(name.dropLast(3))] = head.oid
            } else {
                tags.append((name, head.oid))
            }
        }
        return tags.compactMap { tag in
            var id = tag.id
            var target = peeled[tag.name] ?? tag.id
            var existing = git_oid()
            guard git_odb_exists(odb, &id) == 0, git_odb_exists(odb, &target) == 1,
                  git_reference_name_to_id(&existing, pointer, tag.name) != 0 else { return nil }
            return tag.name
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
    ///
    /// With `includingTags`, every local tag goes too, as with
    /// `git push --tags`; see ``PushedTags`` for what becomes of them.
    @discardableResult
    public func push(
        to remote: String? = nil,
        force: Bool = false,
        includingTags: Bool = false,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws -> PushResult {
        defer { transfer?.finish() }
        return try pushCurrentBranch(
            to: remote, force: force, includingTags: includingTags,
            session: RemoteSession(transfer: transfer, credentials: credentials)
        )
    }

    func pushCurrentBranch(
        to remote: String?, force: Bool, includingTags: Bool = false, session: RemoteSession
    ) throws -> PushResult {
        guard case .branch(let branchReference, _) = try head() else { throw RemoteError.notOnBranch }
        let upstream = upstreamConfiguration(of: branchReference)
        let remoteName = try remote ?? upstream?.remote ?? defaultRemoteName()
        // An upstream on another remote than the one asked for does not apply.
        let destination = upstream.flatMap { $0.remote == remoteName ? $0.merge : nil } ?? branchReference
        // Only a branch with no upstream at all gets one; pushing elsewhere
        // leaves an existing upstream alone.
        return try pushBranch(
            branchReference, to: remoteName, as: destination, setUpstream: upstream?.merge == nil, force: force,
            includingTags: includingTags, session: session
        )
    }

    /// Pushes any local branch, by its full reference name, to a branch of
    /// a chosen name on a chosen remote: the same name when `remoteBranch`
    /// is `nil`. With `setUpstream`, the local branch then tracks it.
    /// A forced push has the same safeguard as ``push(to:force:includingTags:credentials:transfer:)``,
    /// and `includingTags` takes every local tag along in the same way.
    @discardableResult
    public func push(
        branch localReference: String,
        to remote: String,
        as remoteBranch: String? = nil,
        setUpstream: Bool = false,
        force: Bool = false,
        includingTags: Bool = false,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws -> PushResult {
        defer { transfer?.finish() }
        guard localReference.hasPrefix("refs/heads/") else { throw BranchingError.notABranch(localReference) }
        let name = remoteBranch?.trimmingCharacters(in: .whitespaces) ?? ""
        let destination = name.isEmpty
            ? localReference : (name.hasPrefix("refs/") ? name : "refs/heads/" + name)
        return try pushBranch(
            localReference, to: remote, as: destination, setUpstream: setUpstream, force: force,
            includingTags: includingTags, session: RemoteSession(transfer: transfer, credentials: credentials)
        )
    }

    private func pushBranch(
        _ branchReference: String, to remoteName: String, as destination: String, setUpstream: Bool, force: Bool,
        includingTags: Bool = false, session: RemoteSession
    ) throws -> PushResult {
        var leases: [String: OID?] = [:]
        if force {
            leases[destination] = trackingTarget(of: destination, on: remoteName)
        }
        // Only the branch is ever forced; tags that go along never are.
        let branchRefspec = (force ? "+" : "") + "\(branchReference):\(destination)"
        var tags: PushedTags?
        if includingTags {
            tags = try pushWithAllTags(branchRefspec, to: remoteName, leases: leases, session: session)
        } else {
            try pushReferences([branchRefspec], to: remoteName, leases: leases, session: session)
        }
        if setUpstream {
            let branchName = String(branchReference.dropFirst("refs/heads/".count))
            try setUpstreamConfiguration(of: branchName, remote: remoteName, merge: destination)
        }
        return PushResult(remote: remoteName, reference: destination, setUpstream: setUpstream, tags: tags)
    }

    /// Pushes refspecs to a remote and checks what the remote said about
    /// each. `leases` are the force-with-lease expectations, by remote
    /// reference name. With `tagsAlong`, tags go with a branch: the remote
    /// turning a tag down does not fail the push but comes back, by full
    /// name with the remote's reason, and protected tags the remote has
    /// elsewhere are all noted in the session (see `RemoteSession.tagConflicts`).
    @discardableResult
    func pushReferences(
        _ refspecs: [String], to remoteName: String, leases: [String: OID?] = [:], protectedTags: [String: OID] = [:],
        tagsAlong: Bool = false, session: RemoteSession
    ) throws -> [(reference: String, reason: String)] {
        let remotePointer = try lookupRemote(remoteName)
        defer { git_remote_free(remotePointer) }
        if let url = (git_remote_pushurl(remotePointer) ?? git_remote_url(remotePointer)).map({ String(cString: $0) }) {
            try useResolvedURL(url, for: remotePointer, push: git_remote_pushurl(remotePointer) != nil)
        }
        session.leases = leases
        session.protectedTags = protectedTags
        session.collectsTagConflicts = tagsAlong
        session.tagConflicts = []
        session.tagUpdates = []
        session.failure = nil
        session.rejections = []
        session.report(TransferProgress(phase: .connecting))

        var options = git_push_options()
        try check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)))
        options.callbacks = session.callbacks()
        let code = withStringArray(refspecs) { refspecs in
            withExtendedLifetime(session) {
                git_remote_push(remotePointer, &refspecs, &options)
            }
        }
        if code == GIT_ENONFASTFORWARD.rawValue, !session.isCancelled {
            let destination = refspecs.first?.split(separator: ":").last.map(String.init) ?? ""
            throw RemoteError.nonFastForward(branch: shortName(of: destination))
        }
        try session.check(code)
        let tolerated = tagsAlong ? session.rejections.filter { $0.reference.hasPrefix("refs/tags/") } : []
        if let rejection = session.rejections.first(where: { rejection in
            !tolerated.contains { $0.reference == rejection.reference }
        }) {
            throw RemoteError.pushRejected(reference: rejection.reference, reason: rejection.reason)
        }
        return tolerated
    }

    // MARK: Tags and branches on a remote

    /// Pushes tags, by full reference name, to a remote. A tag the remote
    /// already has at another commit is refused, as git refuses it.
    public func pushTags(
        _ tags: [String], to remote: String,
        credentials: (any CredentialProvider)? = nil, transfer: Transfer? = nil
    ) throws {
        defer { transfer?.finish() }
        guard !tags.isEmpty else { return }
        let names = tags.map { $0.hasPrefix("refs/tags/") ? $0 : "refs/tags/" + $0 }
        var targets: [String: OID] = [:]
        for name in names {
            var oid = git_oid()
            try check(git_reference_name_to_id(&oid, pointer, name))
            targets[name] = OID(oid)
        }
        try pushReferences(
            names.map { "\($0):\($0)" }, to: remote, protectedTags: targets,
            session: RemoteSession(transfer: transfer, credentials: credentials)
        )
    }

    /// Pushes every local tag to a remote, as `git push --tags` does.
    /// Returns how many tags there were.
    @discardableResult
    public func pushAllTags(
        to remote: String, credentials: (any CredentialProvider)? = nil, transfer: Transfer? = nil
    ) throws -> Int {
        let tags = try referenceNames(matching: "refs/tags/*")
        try pushTags(tags, to: remote, credentials: credentials, transfer: transfer)
        return tags.count
    }

    /// Deletes a tag on a remote. The local tag, if there is one, is kept.
    public func deleteRemoteTag(
        _ tag: String, on remote: String,
        credentials: (any CredentialProvider)? = nil, transfer: Transfer? = nil
    ) throws {
        defer { transfer?.finish() }
        let name = tag.hasPrefix("refs/tags/") ? tag : "refs/tags/" + tag
        try pushReferences([":" + name], to: remote, session: RemoteSession(transfer: transfer, credentials: credentials))
    }

    /// Deletes a branch on its remote, given by its remote branch's full
    /// name (`refs/remotes/origin/topic`), and the remote branch here.
    public func deleteRemoteBranch(
        _ remoteBranch: String, credentials: (any CredentialProvider)? = nil, transfer: Transfer? = nil
    ) throws {
        defer { transfer?.finish() }
        let (remote, reference) = try remoteSide(of: remoteBranch)
        try pushReferences([":" + reference], to: remote, session: RemoteSession(transfer: transfer, credentials: credentials))
        try removeTrackingReference(remoteBranch)
    }

    /// Renames a branch on its remote: pushes its commit under the new name,
    /// then deletes the old name, in one push. Local branches that followed
    /// the old name follow the new one. Returns the new remote branch's
    /// full name.
    @discardableResult
    public func renameRemoteBranch(
        _ remoteBranch: String, to newName: String,
        credentials: (any CredentialProvider)? = nil, transfer: Transfer? = nil
    ) throws -> String {
        defer { transfer?.finish() }
        let (remote, reference) = try remoteSide(of: remoteBranch)
        let name = newName.trimmingCharacters(in: .whitespaces)
        var valid: Int32 = 0
        try check(git_branch_name_is_valid(&valid, name))
        guard valid != 0 else { throw BranchingError.notABranch(name) }
        let destination = "refs/heads/" + name
        let tip = try commitID(ofReference: remoteBranch)
        // Pushed by commit, not by the remote branch's name: the push
        // rewrites that name when the deletion lands.
        try pushReferences(
            ["\(tip.hex):\(destination)", ":" + reference], to: remote,
            session: RemoteSession(transfer: transfer, credentials: credentials)
        )
        try removeTrackingReference(remoteBranch)
        let renamed = "refs/remotes/\(remote)/\(name)"
        // The push records the new name here only if it maps through a
        // fetch refspec; make sure it is there either way.
        var oid = tip.raw
        var created: OpaquePointer?
        try check(git_reference_create(&created, pointer, renamed, &oid, 1, "push: renamed from \(reference)"))
        git_reference_free(created)

        for branch in try referenceNames(matching: "refs/heads/*") {
            if let upstream = upstreamConfiguration(of: branch), upstream.remote == remote, upstream.merge == reference {
                try setUpstreamConfiguration(
                    of: String(branch.dropFirst("refs/heads/".count)), remote: remote, merge: destination
                )
            }
        }
        return renamed
    }

    // MARK: Pruning

    /// Removes the remote branches whose branch is gone from the remote, as
    /// `git remote prune` does: the remote is asked which branches it has,
    /// but nothing is fetched and no other remote branch moves. Returns the
    /// full names of the remote branches removed.
    @discardableResult
    public func pruneRemote(
        _ name: String, credentials: (any CredentialProvider)? = nil, transfer: Transfer? = nil
    ) throws -> [String] {
        defer { transfer?.finish() }
        let session = RemoteSession(transfer: transfer, credentials: credentials)
        let remote = try lookupRemote(name)
        defer { git_remote_free(remote) }
        if let url = git_remote_url(remote).map({ String(cString: $0) }) {
            try useResolvedURL(url, for: remote, push: false)
        }
        let before = Set(try referenceNames(matching: "refs/remotes/\(name)/*"))
        session.report(TransferProgress(phase: .connecting))
        var callbacks = session.callbacks()
        try withExtendedLifetime(session) {
            try session.check(git_remote_connect(remote, GIT_DIRECTION_FETCH, &callbacks, nil, nil))
            defer { git_remote_disconnect(remote) }
            try session.check(git_remote_prune(remote, &callbacks))
        }
        return before.subtracting(try referenceNames(matching: "refs/remotes/\(name)/*")).sorted()
    }

    // MARK: Pushing a commit

    /// Pushes a commit to a branch of a chosen name on a remote, as
    /// `git push <remote> <commit>:refs/heads/<name>` does, creating the
    /// branch there if it is new. Nothing here changes but the remote
    /// branch, which follows the push.
    ///
    /// A push that would drop commits on the remote is refused, unless
    /// `force` is set; even then it is refused if the remote branch moved
    /// since it was last fetched.
    @discardableResult
    public func push(
        commit id: OID,
        to remote: String,
        as remoteBranch: String,
        force: Bool = false,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws -> PushResult {
        defer { transfer?.finish() }
        let destination = try Self.branchDestination(remoteBranch)
        var leases: [String: OID?] = [:]
        if force {
            leases[destination] = trackingTarget(of: destination, on: remote)
        }
        try pushReferences(
            [(force ? "+" : "") + "\(id.hex):\(destination)"], to: remote, leases: leases,
            session: RemoteSession(transfer: transfer, credentials: credentials)
        )
        return PushResult(remote: remote, reference: destination, setUpstream: false)
    }

    /// Whether pushing `id` to a branch on `remote` only adds commits to it,
    /// as far as the last fetch knows: when the remote branch is not known
    /// here, or its commit is `id` or in `id`'s history.
    public func pushWouldFastForward(_ id: OID, to remote: String, as remoteBranch: String) throws -> Bool {
        let destination = try Self.branchDestination(remoteBranch)
        guard let current = trackingTarget(of: destination, on: remote), current != id else { return true }
        var commit = id.raw, ancestor = current.raw
        let result = git_graph_descendant_of(pointer, &commit, &ancestor)
        try check(result)
        return result == 1
    }

    /// `refs/heads/<name>` for a branch name, which must be a valid one.
    private static func branchDestination(_ remoteBranch: String) throws -> String {
        let name = remoteBranch.trimmingCharacters(in: .whitespaces)
        let destination = name.hasPrefix("refs/") ? name : "refs/heads/" + name
        var valid: Int32 = 0
        try check(git_reference_name_is_valid(&valid, destination))
        guard valid != 0, !name.isEmpty else { throw BranchingError.notABranch(name) }
        return destination
    }

    /// The remote, and the reference on it, that a remote branch stands for.
    private func remoteSide(of remoteBranch: String) throws -> (remote: String, reference: String) {
        guard remoteBranch.hasPrefix("refs/remotes/") else { throw BranchingError.notABranch(remoteBranch) }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try check(git_branch_remote_name(&buffer, pointer, remoteBranch))
        let remote = String(cString: buffer.ptr)
        let remotePointer = try lookupRemote(remote)
        defer { git_remote_free(remotePointer) }
        var source = git_buf()
        defer { git_buf_dispose(&source) }
        for index in 0..<git_remote_refspec_count(remotePointer) {
            guard let refspec = git_remote_get_refspec(remotePointer, index),
                  git_refspec_direction(refspec) == GIT_DIRECTION_FETCH,
                  git_refspec_dst_matches(refspec, remoteBranch) != 0,
                  git_refspec_rtransform(&source, refspec, remoteBranch) == 0,
                  let name = source.ptr else { continue }
            return (remote, String(cString: name))
        }
        let prefix = "refs/remotes/\(remote)/"
        return (remote, "refs/heads/" + remoteBranch.dropFirst(prefix.count))
    }

    private func removeTrackingReference(_ name: String) throws {
        var reference: OpaquePointer?
        guard git_reference_lookup(&reference, pointer, name) == 0 else { return }
        defer { git_reference_free(reference) }
        try check(git_reference_delete(reference))
    }

    // MARK: Pull

    /// Fetches the current branch's upstream remote, then brings the branch
    /// up to its upstream as `pull.rebase` and `pull.ff` in the repository's
    /// configuration say, merging when they say nothing. A merge that
    /// conflicts leaves the repository merging.
    public func pull(
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws -> PullResult {
        try pull(options: PullOptions(), credentials: credentials, transfer: transfer).result
    }

    /// Fetches the current branch's upstream remote, then merges, rebases or
    /// fast-forwards onto the upstream as `options` say, setting local
    /// changes aside first when `options.autostash` is set.
    public func pull(
        options: PullOptions,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws -> PullOutcome {
        defer { transfer?.finish() }
        return try pullUpstream(options: options, session: RemoteSession(transfer: transfer, credentials: credentials))
    }

    /// Fetches a remote branch's remote, then brings the current branch up
    /// to that remote branch, given by its full name
    /// (`refs/remotes/origin/topic`), as `options` say.
    public func pull(
        from remoteBranch: String,
        options: PullOptions,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws -> PullOutcome {
        defer { transfer?.finish() }
        guard case .branch(let branchReference, _) = try head() else { throw RemoteError.notOnBranch }
        let (remote, reference) = try remoteSide(of: remoteBranch)
        try fetchRemotes(
            remote, prune: true, tags: .automatic, session: RemoteSession(transfer: transfer, credentials: credentials)
        )
        guard (try? commitID(ofReference: remoteBranch)) != nil else {
            throw RemoteError.remoteBranchGone(shortName(of: remoteBranch))
        }
        let mode = options.mode ?? configuredPullMode(for: branchReference) ?? .merge
        return try integrateWithAutostash(
            remoteBranch, mode: mode, autostash: options.autostash,
            message: mergeMessage(branch: reference, remote: remote)
        )
    }

    func pullUpstream(options: PullOptions, session: RemoteSession) throws -> PullOutcome {
        guard case .branch(let branchReference, _) = try head() else { throw RemoteError.notOnBranch }
        let branchName = String(branchReference.dropFirst("refs/heads/".count))
        guard let upstream = upstreamConfiguration(of: branchReference), let merge = upstream.merge else {
            throw RemoteError.noUpstream(branch: branchName)
        }
        try fetchRemotes(upstream.remote, prune: true, tags: .automatic, session: session)

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
        let upstreamName = String(cString: git_reference_name(upstreamReference))
        git_reference_free(upstreamReference)

        let mode = options.mode ?? configuredPullMode(for: branchReference) ?? .merge
        return try integrateWithAutostash(
            upstreamName, mode: mode, autostash: options.autostash,
            message: mergeMessage(branch: merge, remote: upstream.remote)
        )
    }

    /// git's message for merging a branch of a remote.
    private func mergeMessage(branch reference: String, remote: String) -> String {
        let remoteURL = (try? remoteURL(of: remote)).flatMap { $0 } ?? remote
        return "Merge branch '\(shortName(of: reference))' of \(remoteURL)"
    }

    private func integrateWithAutostash(
        _ reference: String, mode: PullMode, autostash: Bool, message: String
    ) throws -> PullOutcome {
        guard autostash else {
            return PullOutcome(result: try integrate(reference, mode: mode, message: message), autostash: .notNeeded)
        }
        let stashed = try withAutostash(message: "autostash before pulling") { repository in
            try repository.integrate(reference, mode: mode, message: message)
        }
        return PullOutcome(result: stashed.value, autostash: stashed.autostash)
    }

    /// Brings `HEAD`'s branch up to a fetched reference: a fast-forward when
    /// it has nothing of its own, otherwise a merge or a rebase, through the
    /// same engine as merging and rebasing a branch.
    private func integrate(_ reference: String, mode: PullMode, message: String) throws -> PullResult {
        try requireNoOperation()
        var referencePointer: OpaquePointer?
        try check(git_reference_lookup(&referencePointer, pointer, reference))
        defer { git_reference_free(referencePointer) }
        var theirs: OpaquePointer?
        try check(git_annotated_commit_from_ref(&theirs, pointer, referencePointer))
        defer { git_annotated_commit_free(theirs) }

        var analysis = git_merge_analysis_t(rawValue: 0)
        var preference = git_merge_preference_t(rawValue: 0)
        var heads: [OpaquePointer?] = [theirs]
        try check(git_merge_analysis(&analysis, &preference, pointer, &heads, 1))
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return .upToDate
        }
        let canFastForward = analysis.rawValue
            & (GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue | GIT_MERGE_ANALYSIS_UNBORN.rawValue) != 0

        if canFastForward || mode == .merge {
            switch try merge(reference, mode: .fastForwardWhenPossible, message: message, fastForwardLog: "pull: Fast-forward") {
            case .upToDate: return .upToDate
            case .fastForwarded(let id): return .fastForwarded(to: id)
            case .committed(let id): return .merged(commit: id)
            case .conflicts(let paths): return .conflicts(paths: paths)
            }
        }
        switch mode {
        case .fastForwardOnly:
            throw RemoteError.cannotFastForward(branch: shortName(of: try head().branchName ?? "HEAD"),
                                                onto: shortName(of: reference))
        case .rebase:
            switch try rebase(onto: reference) {
            case .finished:
                return .rebased(onto: try commitID(ofReference: reference))
            case .stopped(let commit, let conflicts):
                return .rebaseStopped(at: commit, conflicts: conflicts)
            }
        case .merge:
            preconditionFailure("Merging is handled above.")
        }
    }

    /// How the repository's configuration says a branch, by full reference
    /// name, should be pulled: `pull.ff = only` first, as git puts it first,
    /// then `branch.<name>.rebase`, then `pull.rebase`. `nil` when none of
    /// them is set.
    public func configuredPullMode(for branchReference: String? = nil) -> PullMode? {
        var configuration: OpaquePointer?
        guard git_repository_config_snapshot(&configuration, pointer) == 0 else { return nil }
        defer { git_config_free(configuration) }
        if GitEnvironment.string(for: "pull.ff", in: configuration)?.lowercased() == "only" {
            return .fastForwardOnly
        }
        let branch = (branchReference ?? (try? head())?.branchName).map { shortName(of: $0) }
        let rebase = branch.flatMap { GitEnvironment.string(for: "branch.\($0).rebase", in: configuration) }
            ?? GitEnvironment.string(for: "pull.rebase", in: configuration)
        switch rebase?.lowercased() {
        case "true", "yes", "on", "1", "merges", "m", "interactive", "i": return .rebase
        case "false", "no", "off", "0": return .merge
        default: return nil
        }
    }

    // MARK: Sync

    /// Pulls the current branch as `options` say, then pushes it, under one
    /// progress display. A pull that stops part way, on conflicts, pushes
    /// nothing. `includingTags` is as for ``push(to:force:includingTags:credentials:transfer:)``.
    public func sync(
        options: PullOptions,
        includingTags: Bool = false,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) throws -> SyncResult {
        defer { transfer?.finish() }
        let pulled = try pullUpstream(options: options, session: RemoteSession(transfer: transfer, credentials: credentials))
        switch pulled.result {
        case .conflicts, .rebaseStopped:
            return SyncResult(pull: pulled, push: nil)
        case .upToDate, .fastForwarded, .merged, .rebased:
            let pushed = try pushCurrentBranch(
                to: nil, force: false, includingTags: includingTags,
                session: RemoteSession(transfer: transfer, credentials: credentials)
            )
            return SyncResult(pull: pulled, push: pushed)
        }
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

    /// The separate URL a remote pushes to, if it has one.
    public func pushURL(ofRemote name: String) throws -> String? {
        let remote = try lookupRemote(name)
        defer { git_remote_free(remote) }
        return git_remote_pushurl(remote).map { String(cString: $0) }
    }

    /// Gives a remote a separate URL to push to, or with `nil` (or an empty
    /// string) makes it push to its fetch URL again.
    public func setPushURL(_ url: String?, ofRemote name: String) throws {
        let url = url?.trimmingCharacters(in: .whitespaces)
        if let url, !url.isEmpty {
            try check(git_remote_set_pushurl(pointer, name, url))
            return
        }
        git_remote_free(try lookupRemote(name))
        var configuration: OpaquePointer?
        try check(git_repository_config(&configuration, pointer))
        defer { git_config_free(configuration) }
        let code = git_config_delete_entry(configuration, "remote.\(name).pushurl")
        if code != GIT_ENOTFOUND.rawValue { try check(code) }
    }

    // MARK: Helpers

    private func remoteNames() throws -> [String] {
        var names = git_strarray()
        try check(git_remote_list(&names, pointer))
        defer { git_strarray_dispose(&names) }
        return (0..<names.count).compactMap { names.strings[$0].map { String(cString: $0) } }
    }

    /// The full names of the references matching a glob, such as `refs/tags/*`.
    func referenceNames(matching glob: String) throws -> [String] {
        var iterator: OpaquePointer?
        try check(git_reference_iterator_glob_new(&iterator, pointer, glob))
        defer { git_reference_iterator_free(iterator) }
        var names: [String] = []
        var name: UnsafePointer<CChar>?
        while git_reference_next_name(&name, iterator) == 0 {
            if let name { names.append(String(cString: name)) }
        }
        return names
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

    // MARK: Remote URLs

    /// Hands libgit2 the resolved form of a relative remote URL for this
    /// one operation, leaving the configuration as it is. git reads such a
    /// path from the top of the working tree, or from the repository folder
    /// of a bare repository, where it runs its commands; libgit2 would read
    /// it against the process's own current folder.
    private func useResolvedURL(_ url: String, for remote: OpaquePointer?, push: Bool) throws {
        guard let path = Self.relativeLocalPath(in: url) else { return }
        let base = git_repository_workdir(pointer).map { URL(filePath: String(cString: $0), directoryHint: .isDirectory) }
            ?? gitDirectory
        let resolved = Self.resolve(path, against: base)
        if push {
            try check(git_remote_set_instance_pushurl(remote, resolved))
        } else {
            try check(git_remote_set_instance_url(remote, resolved))
        }
    }

    /// The path in a URL that is a relative local path: not a URL with a
    /// scheme, not an scp-like `host:path`, and not absolute.
    static func relativeLocalPath(in url: String) -> String? {
        guard !url.isEmpty, !url.contains("://"), !url.hasPrefix("/"), !isSCPLike(url) else { return nil }
        return url
    }

    private static func resolve(_ path: String, against base: URL) -> String {
        var resolved = base.appending(path: path).standardizedFileURL.path(percentEncoded: false)
        // `appending` keeps a trailing slash; git's paths have none.
        while resolved.count > 1, resolved.hasSuffix("/") {
            resolved.removeLast()
        }
        return resolved
    }

    /// `user@host:path` or `host:path`, the short form of an SSH address.
    /// A single letter before the colon would be a Windows drive, and a
    /// slash before it makes it a local path, as git reads it.
    static func isSCPLike(_ url: String) -> Bool {
        guard !url.contains("://"), let colon = url.firstIndex(of: ":") else { return false }
        return !url[..<colon].contains("/") && url[..<colon].count > 1
    }
}
