import Clibgit2
import Foundation

/// A failure in branching, merging or rewriting history that is about the
/// repository's state rather than a libgit2 call.
public enum BranchingError: Error, Hashable, Sendable, LocalizedError {
    /// The branch has commits that neither `HEAD` nor its upstream contain.
    case notMerged(branch: String, commits: Int)
    case notABranch(String)
    case currentBranch(String)
    /// Another operation (merge, rebase, cherry-pick…) has to finish first.
    case operationInProgress(RepositoryState)
    case nothingInProgress
    case unresolvedConflicts
    /// A local branch of that name exists and follows something else.
    case branchExists(String)

    public var errorDescription: String? {
        switch self {
        case .notMerged(let branch, let commits):
            "“\(branch)” has \(commits) \(commits == 1 ? "commit" : "commits") that are not merged into the current branch or its upstream."
        case .notABranch(let name):
            "“\(name)” is not a branch."
        case .currentBranch(let name):
            "“\(name)” is checked out. Switch to another branch first."
        case .operationInProgress(let state):
            "A \(state.operationName) is in progress. Continue or abort it first."
        case .nothingInProgress:
            "There is no merge, rebase, cherry-pick or revert in progress."
        case .unresolvedConflicts:
            "Some files still have conflicts. Resolve them and mark them resolved first."
        case .branchExists(let name):
            "A branch named “\(name)” already exists."
        }
    }
}

extension RepositoryState {
    /// The operation, as a noun in a sentence.
    public var operationName: String {
        switch self {
        case .clean: "nothing"
        case .merging: "merge"
        case .reverting: "revert"
        case .cherryPicking: "cherry-pick"
        case .bisecting: "bisect"
        case .rebasing: "rebase"
        case .applyingMailbox: "patch application"
        }
    }
}

/// How far `reset` goes.
public enum ResetMode: Hashable, Sendable, CaseIterable {
    /// Moves the branch only; the index and working tree keep their changes.
    case soft
    /// Moves the branch and resets the index; the working tree keeps its changes.
    case mixed
    /// Moves the branch and makes the index and working tree match it,
    /// discarding every uncommitted change to tracked files.
    case hard
}

extension Repository {
    /// Switches the working copy to a local branch, given by its full
    /// reference name. Local changes are kept; the switch fails rather than
    /// overwrite one.
    public func checkOut(branch name: String) throws {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, pointer, name))
        defer { git_object_free(object) }
        try checkOutTree(of: object)
        try check(git_repository_set_head(pointer, name))
    }

    /// Switches the working copy to a commit, leaving `HEAD` detached.
    public func checkOut(commit id: OID) throws {
        let commit = try lookupCommit(id)
        defer { git_commit_free(commit) }
        try checkOutTree(of: commit)
        var oid = id.raw
        try check(git_repository_set_head_detached(pointer, &oid))
    }

    /// Switches the working copy to the commit a tag leads to, given by the
    /// tag's full reference name, leaving `HEAD` detached.
    public func checkOut(tag name: String) throws {
        try checkOut(commit: commitID(ofReference: name))
    }

    /// Creates a local branch at a commit, or at `HEAD` when none is given.
    /// Returns the branch's full reference name.
    @discardableResult
    public func createBranch(named name: String, at id: OID? = nil) throws -> String {
        let commit = try id.map(lookupCommit) ?? headCommit()
        defer { git_commit_free(commit) }
        guard let commit else {
            throw GitError(code: GIT_EUNBORNBRANCH.rawValue, message: "There is no commit to branch from yet.")
        }
        var reference: OpaquePointer?
        try check(git_branch_create(&reference, pointer, name, commit, 0))
        defer { git_reference_free(reference) }
        return String(cString: git_reference_name(reference))
    }

    /// Gives a local branch, by its full reference name, a new short name.
    /// Its upstream and, if it is checked out, `HEAD` follow it. Returns the
    /// new full reference name.
    @discardableResult
    public func renameBranch(_ name: String, to newName: String) throws -> String {
        let branch = try localBranch(name)
        defer { git_reference_free(branch) }
        var renamed: OpaquePointer?
        try check(git_branch_move(&renamed, branch, newName, 0))
        defer { git_reference_free(renamed) }
        return String(cString: git_reference_name(renamed))
    }

    /// How many commits on a local branch neither `HEAD` nor the branch's
    /// upstream contain: what deleting it would lose.
    public func unmergedCommitCount(of name: String) throws -> Int {
        let branch = try localBranch(name)
        defer { git_reference_free(branch) }

        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, pointer))
        defer { git_revwalk_free(walk) }
        try check(git_revwalk_push_ref(walk, name))
        if let head = try headCommit() {
            git_commit_free(head)
            try check(git_revwalk_hide_head(walk))
        }
        var upstream: OpaquePointer?
        if git_branch_upstream(&upstream, branch) == 0 {
            defer { git_reference_free(upstream) }
            // An upstream that points nowhere (its remote branch was pruned)
            // simply contains nothing.
            _ = git_revwalk_hide_ref(walk, git_reference_name(upstream))
        }
        var count = 0
        var oid = git_oid()
        while git_revwalk_next(&oid, walk) == 0 {
            count += 1
        }
        return count
    }

    /// How many commits `HEAD` has that `id` does not: the commits a reset
    /// to `id` takes off the branch, or a rebase onto it replays.
    public func headCommitCount(notIn id: OID) throws -> Int {
        guard let head = try head().target else { return 0 }
        var ahead = 0, behind = 0
        var local = head.raw, other = id.raw
        try check(git_graph_ahead_behind(&ahead, &behind, pointer, &local, &other))
        return ahead
    }

    /// Deletes a local branch, by its full reference name. Unless `force` is
    /// set, a branch with commits that neither `HEAD` nor its upstream
    /// contain is refused with `BranchingError.notMerged`.
    public func deleteBranch(_ name: String, force: Bool = false) throws {
        let branch = try localBranch(name)
        defer { git_reference_free(branch) }
        let shortName = String(cString: git_reference_shorthand(branch))
        if git_branch_is_head(branch) == 1 {
            throw BranchingError.currentBranch(shortName)
        }
        if !force {
            let unmerged = try unmergedCommitCount(of: name)
            if unmerged > 0 {
                throw BranchingError.notMerged(branch: shortName, commits: unmerged)
            }
        }
        try check(git_branch_delete(branch))
    }

    /// Makes a local branch follow another branch, both by full reference
    /// name, or follow nothing when `upstream` is `nil`.
    public func setUpstream(of name: String, to upstream: String?) throws {
        let branch = try localBranch(name)
        defer { git_reference_free(branch) }
        guard let upstream else {
            try check(git_branch_set_upstream(branch, nil))
            return
        }
        // libgit2 wants the upstream's short name: `origin/main`, or `main`.
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, upstream))
        defer { git_reference_free(reference) }
        guard git_reference_is_branch(reference) != 0 || git_reference_is_remote(reference) != 0 else {
            throw BranchingError.notABranch(upstream)
        }
        try check(git_branch_set_upstream(branch, git_reference_shorthand(reference)))
    }

    /// Creates a local branch that tracks a remote branch, given by its full
    /// reference name (`refs/remotes/origin/topic`), named after it unless
    /// `name` is given. A local branch of that name which already tracks the
    /// remote branch is reused. Returns the local branch's full reference
    /// name, ready to check out.
    @discardableResult
    public func createTrackingBranch(for remoteBranch: String, named name: String? = nil) throws -> String {
        var remote: OpaquePointer?
        try check(git_reference_lookup(&remote, pointer, remoteBranch))
        defer { git_reference_free(remote) }
        guard git_reference_is_remote(remote) != 0 else { throw BranchingError.notABranch(remoteBranch) }
        let remoteShortName = String(cString: git_reference_shorthand(remote))
        let localName = name ?? remoteShortName.split(separator: "/", maxSplits: 1).last.map(String.init)
            ?? remoteShortName

        var existing: OpaquePointer?
        if git_branch_lookup(&existing, pointer, localName, GIT_BRANCH_LOCAL) == 0 {
            defer { git_reference_free(existing) }
            var upstream: OpaquePointer?
            let tracks = git_branch_upstream(&upstream, existing) == 0
                && String(cString: git_reference_name(upstream)) == remoteBranch
            git_reference_free(upstream)
            guard tracks else { throw BranchingError.branchExists(localName) }
            return String(cString: git_reference_name(existing))
        }

        let fullName = try createBranch(named: localName, at: commitID(ofReference: remoteBranch))
        try setUpstream(of: fullName, to: remoteBranch)
        return fullName
    }

    /// Creates a tag at a commit: annotated when there is a message, which
    /// needs an identity for the tagger, lightweight otherwise. Returns the
    /// tag's full reference name.
    @discardableResult
    public func createTag(named name: String, at id: OID, message: String? = nil) throws -> String {
        var object: OpaquePointer?
        var oid = id.raw
        try check(git_object_lookup(&object, pointer, &oid, GIT_OBJECT_COMMIT))
        defer { git_object_free(object) }

        var created = git_oid()
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            try check(git_tag_create_lightweight(&created, pointer, name, object, 0))
        } else {
            let tagger = try branchingSignature()
            defer { git_signature_free(tagger) }
            try check(git_tag_create(&created, pointer, name, object, tagger, text + "\n", 0))
        }
        return "refs/tags/" + name
    }

    /// Deletes a tag, given by its full reference name or its short name.
    public func deleteTag(_ name: String) throws {
        let shortName = name.hasPrefix("refs/tags/") ? String(name.dropFirst("refs/tags/".count)) : name
        try check(git_tag_delete(pointer, shortName))
    }

    /// Moves the current branch (or a detached `HEAD`) to a commit.
    ///
    /// `.hard` discards every uncommitted change to tracked files; untracked
    /// files are left alone, as git leaves them.
    public func reset(to id: OID, mode: ResetMode) throws {
        var object: OpaquePointer?
        var oid = id.raw
        try check(git_object_lookup(&object, pointer, &oid, GIT_OBJECT_COMMIT))
        defer { git_object_free(object) }
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        let type: git_reset_t = switch mode {
        case .soft: GIT_RESET_SOFT
        case .mixed: GIT_RESET_MIXED
        case .hard: GIT_RESET_HARD
        }
        try check(git_reset(pointer, object, type, &options))
    }

    // MARK: Shared with merging and rebasing

    func checkOutTree(of object: OpaquePointer?) throws {
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try check(git_checkout_tree(pointer, object, &options))
    }

    /// The identity that commits and tags are made as. The caller frees it.
    func branchingSignature() throws -> UnsafeMutablePointer<git_signature> {
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0, let signature else {
            throw RepositoryError.identityNotConfigured
        }
        return signature
    }

    /// The commit a reference leads to, through any tag objects.
    func commitID(ofReference name: String) throws -> OID {
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, name))
        defer { git_reference_free(reference) }
        var object: OpaquePointer?
        try check(git_reference_peel(&object, reference, GIT_OBJECT_COMMIT))
        defer { git_object_free(object) }
        return OID(git_object_id(object))
    }

    /// Looks up a local branch by its full reference name. The caller frees it.
    private func localBranch(_ name: String) throws -> OpaquePointer {
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, name))
        guard let reference, git_reference_is_branch(reference) != 0 else {
            git_reference_free(reference)
            throw BranchingError.notABranch(name)
        }
        return reference
    }
}
