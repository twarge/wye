import Clibgit2
import Foundation

/// How changes are set aside in a stash.
public struct StashOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Stash untracked files too, removing them from the working copy.
    public static let includeUntracked = StashOptions(rawValue: GIT_STASH_INCLUDE_UNTRACKED.rawValue)
    /// Leave the staged changes in place after stashing them.
    public static let keepIndex = StashOptions(rawValue: GIT_STASH_KEEP_INDEX.rawValue)
}

extension Repository {
    /// Sets the local changes aside in a new stash and returns its commit.
    /// Without a message, git's own "WIP on <branch>" is used.
    @discardableResult
    public func saveStash(message: String? = nil, options: StashOptions = []) throws -> OID {
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0 else {
            throw RepositoryError.identityNotConfigured
        }
        defer { git_signature_free(signature) }

        try reloadIndex()
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        var id = git_oid()
        let code = git_stash_save(&id, pointer, signature, message?.isEmpty == false ? message : nil, options.rawValue)
        if code == GIT_ENOTFOUND.rawValue { throw WorkingCopyError.nothingToStash }
        try check(code)
        return OID(id)
    }

    /// Stashes only the changes to `paths`, files or folders, staged and
    /// unstaged, as `git stash push -- <paths>` does: they leave the index
    /// and the working tree, and every other change stays where it is.
    ///
    /// As git's, the stash's index commit holds the whole index and its
    /// working tree commit the index with these paths' files on top.
    /// libgit2's own pathspec stash differs (it starts from `HEAD` and
    /// unstages the other files), so the stash is put together here.
    @discardableResult
    public func saveStash(paths: [String], message: String? = nil, options: StashOptions = []) throws -> OID {
        guard let workingDirectory = git_repository_workdir(pointer).map({ String(cString: $0) }) else {
            throw RepositoryError.noWorkingDirectory
        }
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0 else {
            throw RepositoryError.identityNotConfigured
        }
        defer { git_signature_free(signature) }
        try reloadIndex()

        func isChosen(_ path: String) -> Bool {
            paths.contains { chosen in
                let folder = chosen.hasSuffix("/") ? chosen : chosen + "/"
                return path == chosen || path.hasPrefix(folder)
            }
        }
        let entries = try status().filter { isChosen($0.path) && !$0.isConflicted }
        let tracked = entries.filter { $0.staged != nil || ($0.unstaged != nil && $0.unstaged != .untracked) }
        let untracked = options.contains(.includeUntracked) ? entries.filter { $0.unstaged == .untracked } : []
        guard !tracked.isEmpty || !untracked.isEmpty else { throw WorkingCopyError.nothingToStash }
        guard let head = try headCommit() else { throw PartialStashError.noCommit }
        defer { git_commit_free(head) }

        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        defer { git_index_free(index) }
        var indexTreeID = git_oid()
        try check(git_index_write_tree(&indexTreeID, index))

        // The working tree: the index, with the chosen files as they are on disk.
        let changedOnDisk = tracked.filter { $0.unstaged != nil }.map(\.path)
        let workTreeID = try treeID(startingFrom: indexTreeID, withFilesFrom: workingDirectory, paths: changedOnDisk)
        let untrackedTreeID = untracked.isEmpty
            ? nil : try treeID(startingFrom: nil, withFilesFrom: workingDirectory, paths: untracked.map(\.path))

        let base = try stashBase(of: head)
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workMessage = message.isEmpty ? "WIP on \(base.description)\n" : "On \(base.branch): \(message)\n"
        let indexCommit = try stashCommit(tree: indexTreeID, parents: [head], message: "index on \(base.description)\n", signature)
        defer { git_commit_free(indexCommit) }
        var parents: [OpaquePointer?] = [head, indexCommit]
        var untrackedCommit: OpaquePointer?
        defer { git_commit_free(untrackedCommit) }
        if let untrackedTreeID {
            untrackedCommit = try stashCommit(
                tree: untrackedTreeID, parents: [], message: "untracked files on \(base.description)\n", signature
            )
            parents.append(untrackedCommit)
        }
        let workCommit = try stashCommit(tree: workTreeID, parents: parents, message: workMessage, signature)
        defer { git_commit_free(workCommit) }
        var workID = git_commit_id(workCommit).pointee
        try check(git_reference_ensure_log(pointer, "refs/stash"))
        var reference: OpaquePointer?
        try check(git_reference_create(&reference, pointer, "refs/stash", &workID, 1, workMessage))
        git_reference_free(reference)

        // Now the chosen changes leave: the files go back to HEAD, or with
        // keepIndex to the index, which then stays as it is.
        let trackedPaths = tracked.map(\.path)
        if !trackedPaths.isEmpty {
            if !options.contains(.keepIndex) {
                try unstage(trackedPaths)
            }
            var checkout = git_checkout_options()
            try check(git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
            checkout.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
                | (options.contains(.keepIndex) ? 0 : GIT_CHECKOUT_REMOVE_UNTRACKED.rawValue)
            try reloadIndex()
            try withStringArray(trackedPaths) { array in
                checkout.paths = array
                if options.contains(.keepIndex) {
                    _ = try check(git_checkout_index(pointer, nil, &checkout))
                } else {
                    _ = try check(git_checkout_head(pointer, &checkout))
                }
            }
        }
        let root = URL(filePath: workingDirectory, directoryHint: .isDirectory)
        for entry in untracked {
            try? FileManager.default.removeItem(at: root.appending(path: entry.path))
        }
        return OID(workID)
    }

    /// A tree: `base`'s (or an empty one), with each of `paths` as the file
    /// on disk, or left out where the file is gone.
    private func treeID(startingFrom base: git_oid?, withFilesFrom workingDirectory: String, paths: [String]) throws -> git_oid {
        var index: OpaquePointer?
        try check(git_index_new(&index))
        defer { git_index_free(index) }
        if var base {
            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, pointer, &base))
            defer { git_tree_free(tree) }
            try check(git_index_read_tree(index, tree))
        }
        for path in paths {
            var information = stat()
            guard lstat(workingDirectory + path, &information) == 0 else {
                _ = git_index_remove(index, path, 0)
                continue
            }
            var blob = git_oid()
            try check(git_blob_create_from_workdir(&blob, pointer, path))
            var entry = git_index_entry()
            let mode = information.st_mode & S_IFMT
            entry.mode = mode == S_IFLNK ? GIT_FILEMODE_LINK.rawValue
                : information.st_mode & S_IXUSR != 0 ? GIT_FILEMODE_BLOB_EXECUTABLE.rawValue : GIT_FILEMODE_BLOB.rawValue
            entry.id = blob
            entry.file_size = UInt32(truncatingIfNeeded: information.st_size)
            let copy = strdup(path)
            defer { free(copy) }
            entry.path = UnsafePointer(copy)
            try check(git_index_add(index, &entry))
        }
        var id = git_oid()
        try check(git_index_write_tree_to(&id, index, pointer))
        return id
    }

    /// One of a stash's commits. The caller frees it.
    private func stashCommit(
        tree id: git_oid, parents: [OpaquePointer?], message: String, _ signature: UnsafeMutablePointer<git_signature>?
    ) throws -> OpaquePointer? {
        var treeID = id
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &treeID))
        defer { git_tree_free(tree) }
        var parents = parents
        var commitID = git_oid()
        try check(git_commit_create(
            &commitID, pointer, nil, signature, signature, nil, message, tree, parents.count, &parents
        ))
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, pointer, &commitID))
        return commit
    }

    /// Stashes some of a file's unstaged lines, given by their IDs in
    /// `file`, its unstaged diff as last read with `options`, and takes them
    /// out of the working tree. The stash holds what stashing would have
    /// held had those lines been the only change: its working tree is
    /// `HEAD` with them, and nothing is staged in it.
    ///
    /// A file with staged changes is refused, since its lines were read
    /// against the index rather than `HEAD`.
    @discardableResult
    public func saveStash(
        lines: Set<Int>, of file: FileDiff, message: String? = nil, options diffOptions: DiffOptions = .standard
    ) throws -> OID {
        guard diffOptions.isExact else { throw WorkingCopyError.inexactDiff }
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0 else {
            throw RepositoryError.identityNotConfigured
        }
        defer { git_signature_free(signature) }
        try reloadIndex()

        let source = try patchSource(of: file, side: .unstaged, options: diffOptions)
        let selected = lines.intersection(source.changedLineIDs)
        guard !selected.isEmpty,
              let patch = PatchBuilder.patch(for: source, selecting: selected, reversed: false) else {
            throw WorkingCopyError.nothingSelected
        }
        guard try !hasStagedChanges(to: file.path) else {
            throw PartialStashError.stagedChanges(path: file.path)
        }

        guard let head = try headCommit() else { throw PartialStashError.noCommit }
        defer { git_commit_free(head) }
        let headTree = try tree(of: head)
        defer { git_tree_free(headTree) }
        let workTreeID = try tree(applying: patch, to: headTree)

        // As git words them: "index on main: 1234567 Subject".
        let base = try stashBase(of: head)
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workMessage = message.isEmpty ? "WIP on \(base.description)\n" : "On \(base.branch): \(message)\n"

        var indexID = git_oid()
        var parents: [OpaquePointer?] = [head]
        try check(git_commit_create(
            &indexID, pointer, nil, signature, signature, nil, "index on \(base.description)\n", headTree, 1, &parents
        ))
        var indexCommit: OpaquePointer?
        try check(git_commit_lookup(&indexCommit, pointer, &indexID))
        defer { git_commit_free(indexCommit) }
        var workTree: OpaquePointer?
        var workTreeOID = workTreeID.raw
        try check(git_tree_lookup(&workTree, pointer, &workTreeOID))
        defer { git_tree_free(workTree) }
        parents = [head, indexCommit]
        var workID = git_oid()
        try check(git_commit_create(
            &workID, pointer, nil, signature, signature, nil, workMessage, workTree, 2, &parents
        ))

        // The stash list is the reflog of refs/stash.
        try check(git_reference_ensure_log(pointer, "refs/stash"))
        var reference: OpaquePointer?
        try check(git_reference_create(&reference, pointer, "refs/stash", &workID, 1, workMessage))
        git_reference_free(reference)

        // Now that the lines are safe in the stash, they leave the working tree.
        try discard(lines: selected, of: file, options: diffOptions, untracked: .trash)
        return OID(workID)
    }

    /// The tree `tree` becomes with `patch` applied to it.
    private func tree(applying patch: [UInt8], to tree: OpaquePointer?) throws -> OID {
        var diff: OpaquePointer?
        try patch.withUnsafeBufferPointer { bytes in
            try bytes.withMemoryRebound(to: CChar.self) { text in
                _ = try check(git_diff_from_buffer(&diff, text.baseAddress, text.count))
            }
        }
        defer { git_diff_free(diff) }
        var index: OpaquePointer?
        let code = git_apply_to_tree(&index, pointer, tree, diff, nil)
        guard code == 0 else { throw PatchFileError.doesNotApply(GitError.last(code: code).message) }
        defer { git_index_free(index) }
        var id = git_oid()
        try check(git_index_write_tree_to(&id, index, pointer))
        return OID(id)
    }

    /// Whether the index holds a version of `path` other than `HEAD`'s.
    private func hasStagedChanges(to path: String) throws -> Bool {
        var flags: UInt32 = 0
        let code = git_status_file(&flags, pointer, path)
        if code == GIT_ENOTFOUND.rawValue { return false }
        try check(code)
        let staged = GIT_STATUS_INDEX_NEW.rawValue | GIT_STATUS_INDEX_MODIFIED.rawValue | GIT_STATUS_INDEX_DELETED.rawValue
            | GIT_STATUS_INDEX_RENAMED.rawValue | GIT_STATUS_INDEX_TYPECHANGE.rawValue
        return flags & staged != 0
    }

    /// "main: 1234567 Subject", what git's stash messages are made of.
    private func stashBase(of head: OpaquePointer?) throws -> (branch: String, description: String) {
        var reference: OpaquePointer?
        try check(git_repository_head(&reference, pointer))
        defer { git_reference_free(reference) }
        let name = String(cString: git_reference_name(reference))
        let branch = name == "HEAD" ? "(no branch)" : String(name.dropFirst("refs/heads/".count))
        let short = String(OID(git_commit_id(head)).hex.prefix(7))
        let summary = git_commit_summary(head).map { String(cString: $0) } ?? ""
        return (branch, "\(branch): \(short) \(summary)")
    }

    /// Applies a stash's changes to the working copy and keeps the stash.
    ///
    /// - Parameter restoringIndex: Whether changes that were staged when the
    ///   stash was made are staged again, rather than left unstaged.
    public func applyStash(_ stash: Stash, restoringIndex: Bool = false) throws {
        let position = try currentPosition(of: stash)
        var options = try applyOptions(restoringIndex: restoringIndex)
        try reloadIndex()
        try checkApply(git_stash_apply(pointer, position, &options))
    }

    /// Applies a stash's changes, then drops it. A stash that does not apply
    /// cleanly is kept.
    public func popStash(_ stash: Stash, restoringIndex: Bool = false) throws {
        let position = try currentPosition(of: stash)
        var options = try applyOptions(restoringIndex: restoringIndex)
        try reloadIndex()
        try checkApply(git_stash_pop(pointer, position, &options))
    }

    /// Deletes a stash. Its changes cannot be recovered from the list afterwards.
    public func dropStash(_ stash: Stash) throws {
        try check(git_stash_drop(pointer, try currentPosition(of: stash)))
    }

    // MARK: Snapshots

    /// Saves the local changes, untracked files among them, in a stash
    /// marked as a snapshot, and puts them straight back as they were,
    /// staged changes staged: the work stays in place and a copy that can
    /// be applied later is kept. Returns the snapshot's commit.
    @discardableResult
    public func saveSnapshot(message: String) throws -> OID {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
                .dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon))
        }
        let id = try saveStash(message: Stash.snapshotMarker + text, options: .includeUntracked)
        do {
            var options = try applyOptions(restoringIndex: true)
            try checkApply(git_stash_apply(pointer, 0, &options))
        } catch {
            throw SnapshotError.notRestored(reason: error.localizedDescription)
        }
        return id
    }

    // MARK: Branching from a stash

    /// Makes a branch at the commit a stash was made on, checks it out and
    /// applies the stash there, staged changes staged, then drops the stash,
    /// as `git stash branch` does. A stash that does not apply is kept.
    /// Returns the branch's full reference name.
    @discardableResult
    public func createBranch(fromStash stash: Stash, named name: String) throws -> String {
        let commit = try lookupCommit(stash.id)
        defer { git_commit_free(commit) }
        guard let base = git_commit_parent_id(commit, 0) else { throw WorkingCopyError.stashNotFound }
        let branch = try createBranch(named: name, at: OID(base))
        do {
            try checkOut(branch: branch)
        } catch {
            // As git's `checkout -b`, a checkout that fails makes no branch.
            try? deleteBranch(branch, force: true)
            throw error
        }
        try applyStash(stash, restoringIndex: true)
        try dropStash(stash)
        return branch
    }

    // MARK: A stash as a patch

    /// The changes a stash holds to tracked files, as the patch
    /// `git stash show -p` prints: from the commit it was made on to its
    /// working tree. Its untracked files are not in it, as in git's.
    public func patch(ofStash stash: Stash) throws -> String {
        let commit = try lookupCommit(stash.id)
        defer { git_commit_free(commit) }
        var parent: OpaquePointer?
        try check(git_commit_parent(&parent, commit, 0))
        defer { git_commit_free(parent) }
        let newTree = try tree(of: commit)
        defer { git_tree_free(newTree) }
        let oldTree = try tree(of: parent)
        defer { git_tree_free(oldTree) }
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags = GIT_DIFF_SHOW_BINARY.rawValue
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, pointer, oldTree, newTree, &options))
        defer { git_diff_free(diff) }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try check(git_diff_to_buf(&buffer, diff, GIT_DIFF_FORMAT_PATCH))
        return buffer.ptr.map { String(cString: $0) } ?? ""
    }

    /// Where a stash is in the list now. Positions shift as stashes are made
    /// and dropped, so the stash is found by its commit, not by the position
    /// it had when the list was read.
    private func currentPosition(of stash: Stash) throws -> Int {
        let found = StashSearch(id: stash.id)
        let code = git_stash_foreach(pointer, { index, _, id, payload in
            guard let id, let payload else { return 0 }
            let search = Unmanaged<StashSearch>.fromOpaque(payload).takeUnretainedValue()
            guard OID(id) == search.id else { return 0 }
            search.position = index
            return 1
        }, Unmanaged.passUnretained(found).toOpaque())
        if code < 0 { try check(code) }
        guard let position = found.position else { throw WorkingCopyError.stashNotFound }
        return position
    }

    /// libgit2 keeps the index in memory; another git may have changed it
    /// on disk since, and stashing must start from what is there now.
    private func reloadIndex() throws {
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))
    }

    private func applyOptions(restoringIndex: Bool) throws -> git_stash_apply_options {
        var options = git_stash_apply_options()
        try check(git_stash_apply_options_init(&options, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION)))
        if restoringIndex {
            options.flags = GIT_STASH_APPLY_REINSTATE_INDEX.rawValue
        }
        return options
    }

    private func checkApply(_ code: Int32) throws {
        if code == GIT_EMERGECONFLICT.rawValue || code == GIT_ECONFLICT.rawValue {
            throw WorkingCopyError.stashConflictsWithChanges
        }
        if code == GIT_ENOTFOUND.rawValue { throw WorkingCopyError.stashNotFound }
        try check(code)
    }
}

extension Stash {
    /// What a snapshot's message starts with, after git's "On <branch>: ".
    public static let snapshotMarker = "Snapshot: "

    /// Whether Wye made this stash as a snapshot: a copy of changes that
    /// were left in place.
    public var isSnapshot: Bool {
        subject.hasPrefix(Self.snapshotMarker)
    }

    /// The message without git's "On <branch>: " or "WIP on <branch>: ",
    /// and without the snapshot marker. Branch names cannot hold a colon,
    /// so the first ": " ends git's part.
    public var title: String {
        let text = subject
        return text.hasPrefix(Self.snapshotMarker) ? String(text.dropFirst(Self.snapshotMarker.count)) : text
    }

    private var subject: String {
        for prefix in ["On ", "WIP on "] where message.hasPrefix(prefix) {
            if let colon = message.range(of: ": ") {
                return String(message[colon.upperBound...])
            }
        }
        return message
    }
}

/// Lines of a file that cannot be stashed on their own.
public enum PartialStashError: Error, Hashable, Sendable, LocalizedError {
    /// The file has staged changes, which its lines were read on top of.
    case stagedChanges(path: String)
    /// There is no commit to make a stash on yet.
    case noCommit

    public var errorDescription: String? {
        switch self {
        case .stagedChanges(let path):
            "“\(path)” has staged changes. Unstage them to stash some of its lines, or stash the whole file."
        case .noCommit:
            "There is no commit yet to stash changes on."
        }
    }
}

/// A snapshot that was saved but could not be put back in place.
public enum SnapshotError: Error, Hashable, Sendable, LocalizedError {
    case notRestored(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notRestored(let reason):
            "The snapshot was saved, but the changes could not be put back: \(reason) "
                + "They are safe in the snapshot; apply it from the stashes to get them back."
        }
    }
}

/// Carries a stash search through libgit2's callback, which cannot capture Swift state.
private final class StashSearch {
    let id: OID
    var position: Int?

    init(id: OID) {
        self.id = id
    }
}
