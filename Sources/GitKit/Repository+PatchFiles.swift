import Clibgit2
import Foundation

/// Where `applyPatch` makes a patch's changes.
public enum PatchTarget: Hashable, Sendable, CaseIterable {
    /// The files only, as `git apply`.
    case workingTree
    /// The files and the index, as `git apply --index`.
    case workingTreeAndIndex
    /// The index only, leaving the files alone, as `git apply --cached`.
    case index

    var location: git_apply_location_t {
        switch self {
        case .workingTree: GIT_APPLY_LOCATION_WORKDIR
        case .workingTreeAndIndex: GIT_APPLY_LOCATION_BOTH
        case .index: GIT_APPLY_LOCATION_INDEX
        }
    }
}

/// A patch file that cannot be made or applied.
public enum PatchFileError: Error, Hashable, Sendable, LocalizedError {
    /// A merge has no single change to write down.
    case mergeCommit
    case notAPatch
    case doesNotApply(String)

    public var errorDescription: String? {
        switch self {
        case .mergeCommit:
            "A merge commit cannot be saved as a patch: it has more than one parent to compare with."
        case .notAPatch:
            "The file holds no changes that can be applied."
        case .doesNotApply(let reason):
            "The patch does not apply: \(reason)"
        }
    }
}

/// A new message that cannot be used.
public enum RewordError: Error, Hashable, Sendable, LocalizedError {
    case emptyMessage

    public var errorDescription: String? {
        "A commit needs a message."
    }
}

extension Repository {
    /// A commit as a patch in the mailbox format `git format-patch` writes,
    /// which `git am` and `applyPatch` both read.
    public func formatPatch(for id: OID) throws -> String {
        let commit = try lookupCommit(id)
        defer { git_commit_free(commit) }
        guard git_commit_parentcount(commit) <= 1 else { throw PatchFileError.mergeCommit }

        // libgit2 has no initializer for these options; build what its
        // GIT_EMAIL_CREATE_OPTIONS_INIT does: binary diffs and renames, as
        // `git format-patch` writes them.
        var options = git_email_create_options()
        options.version = 1
        try check(git_diff_options_init(&options.diff_opts, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.diff_opts.flags = GIT_DIFF_SHOW_BINARY.rawValue
        try check(git_diff_find_options_init(&options.diff_find_opts, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)))

        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try check(git_email_create_from_commit(&buffer, commit, &options))
        guard let text = buffer.ptr else { return "" }
        return String(cString: text)
    }

    /// The name `git format-patch` gives a commit's patch: its number and
    /// its subject, each run of anything but letters, digits, dots and
    /// underscores turned into one dash, runs of dots into one dot, cut to
    /// the length git allows.
    public nonisolated static func patchFileName(for commit: Commit, number: Int = 1) -> String {
        var name = ""
        var pendingDash = false
        var lastWasDot = false
        for character in commit.summary.unicodeScalars {
            let isKept = character.isASCII
                && (CharacterSet.alphanumerics.contains(character) || character == "." || character == "_")
            guard isKept else {
                pendingDash = true
                lastWasDot = false
                continue
            }
            if character == ".", lastWasDot, !pendingDash { continue }
            if pendingDash, !name.isEmpty { name.append("-") }
            pendingDash = false
            lastWasDot = character == "."
            name.unicodeScalars.append(character)
        }
        while name.hasSuffix(".") || name.hasSuffix("-") { name.removeLast() }
        // git keeps the whole name, number and ".patch" included, under 64 characters.
        let prefix = String(format: "%04d-", number)
        name = String(name.prefix(63 - prefix.count - ".patch".count))
        return (name.isEmpty ? String(prefix.dropLast()) : prefix + name) + ".patch"
    }

    /// Applies a patch, as `git format-patch` or `git diff` writes one, to
    /// the working tree, the index or both. Nothing changes unless every
    /// file applies.
    public func applyPatch(_ patch: Data, to target: PatchTarget) throws {
        if target != .index, git_repository_workdir(pointer) == nil {
            throw RepositoryError.noWorkingDirectory
        }
        try withPatchDiff(patch) { diff in
            // Start from the index on disk, which another git may have changed.
            git_index_free(try branchingIndex())
            var options = git_apply_options()
            try check(git_apply_options_init(&options, UInt32(GIT_APPLY_OPTIONS_VERSION)))
            options.flags = GIT_APPLY_CHECK.rawValue
            let checked = git_apply(pointer, diff, target.location, &options)
            if checked < 0 {
                throw PatchFileError.doesNotApply(GitError.last(code: checked).message)
            }
            try check(git_apply(pointer, diff, target.location, nil))
        }
    }

    /// Whether a patch would apply, without applying it.
    public func patchApplies(_ patch: Data, to target: PatchTarget) throws -> Bool {
        try withPatchDiff(patch) { diff in
            var options = git_apply_options()
            try check(git_apply_options_init(&options, UInt32(GIT_APPLY_OPTIONS_VERSION)))
            options.flags = GIT_APPLY_CHECK.rawValue
            return git_apply(pointer, diff, target.location, &options) == 0
        }
    }

    private func withPatchDiff<Result>(_ patch: Data, _ body: (OpaquePointer?) throws -> Result) throws -> Result {
        var diff: OpaquePointer?
        let code = patch.withUnsafeBytes { bytes in
            git_diff_from_buffer(&diff, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count)
        }
        guard code == 0 else { throw PatchFileError.notAPatch }
        defer { git_diff_free(diff) }
        guard git_diff_num_deltas(diff) > 0 else { throw PatchFileError.notAPatch }
        return try body(diff)
    }

    // MARK: Rewording

    /// Gives the commit `HEAD` points at a new message, keeping its tree,
    /// parents and author. The index and working tree are not touched, so
    /// staged changes stay staged rather than going into the commit.
    @discardableResult
    public func rewordHead(message: String) throws -> OID {
        let state = RepositoryState(git_repository_state(pointer))
        guard state == .clean else { throw WorkingCopyError.operationUnderWay(state) }
        guard let head = try headCommit() else { throw WorkingCopyError.nothingToAmend }
        defer { git_commit_free(head) }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RewordError.emptyMessage }
        let committer = try branchingSignature()
        defer { git_signature_free(committer) }
        var id = git_oid()
        try check(git_commit_amend(&id, head, "HEAD", nil, committer, nil, text + "\n", nil))
        return OID(id)
    }

    /// The remote branch that already has a commit, if one does: rewriting
    /// that commit here would need a force push to reach the remote.
    public func remoteBranch(containing id: OID) throws -> String? {
        var iterator: OpaquePointer?
        try check(git_reference_iterator_glob_new(&iterator, pointer, "refs/remotes/*"))
        defer { git_reference_iterator_free(iterator) }
        var commit = id.raw
        var reference: OpaquePointer?
        while git_reference_next(&reference, iterator) == 0 {
            defer { git_reference_free(reference) }
            guard git_reference_type(reference) == GIT_REFERENCE_DIRECT, let target = git_reference_target(reference) else {
                continue
            }
            var tip = target.pointee
            if OID(target) == id || git_graph_descendant_of(pointer, &tip, &commit) == 1 {
                return String(cString: git_reference_shorthand(reference))
            }
        }
        return nil
    }
}
