import Clibgit2
import Foundation

extension Repository {
    /// The files that differ from `HEAD`, staged or not.
    public func status() throws -> [StatusEntry] {
        guard !isBare else { return [] }
        var options = git_status_options()
        try check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
            | GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue

        var list: OpaquePointer?
        try check(git_status_list_new(&list, pointer, &options))
        defer { git_status_list_free(list) }
        return (0..<git_status_list_entrycount(list)).compactMap { index in
            git_status_byindex(list, index).flatMap { StatusEntry($0.pointee) }
        }
    }

    /// Records the working tree's version of each path in the index.
    public func stage(_ paths: [String]) throws {
        guard let workingDirectory = git_repository_workdir(pointer).map({ String(cString: $0) }) else {
            throw RepositoryError.noWorkingDirectory
        }
        let index = try index()
        defer { git_index_free(index) }
        for path in paths {
            // A file that is gone from the working tree is staged as a deletion.
            var information = stat()
            if lstat(workingDirectory + path, &information) == 0 {
                try check(git_index_add_bypath(index, path))
            } else {
                try check(git_index_remove_bypath(index, path))
            }
        }
        try check(git_index_write(index))
    }

    /// Returns each path in the index to its state in `HEAD`.
    public func unstage(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let head = try headCommit()
        defer { git_commit_free(head) }
        if let head {
            try withStringArray(paths) { paths in
                _ = try check(git_reset_default(pointer, head, &paths))
            }
        } else {
            // With no commits yet, unstaging means dropping the entry.
            let index = try index()
            defer { git_index_free(index) }
            for path in paths {
                try check(git_index_remove_bypath(index, path))
            }
            try check(git_index_write(index))
        }
    }

    /// The identity new commits are attributed to, from the repository's and
    /// the global configuration.
    public func identity() -> GitIdentity? {
        var configuration: OpaquePointer?
        guard git_repository_config(&configuration, pointer) == 0 else { return nil }
        defer { git_config_free(configuration) }
        guard let name = GitEnvironment.string(for: "user.name", in: configuration),
              let email = GitEnvironment.string(for: "user.email", in: configuration) else { return nil }
        return GitIdentity(name: name, email: email)
    }

    /// Commits the index on top of `HEAD`, concluding a merge if one is under way.
    ///
    /// Refused during a rebase, cherry-pick or revert: those keep their place
    /// in files that committing here would clear, and are carried on with
    /// `continueOperation()` instead.
    @discardableResult
    public func commit(message: String) throws -> OID {
        let state = RepositoryState(git_repository_state(pointer))
        guard state == .clean || state == .merging else {
            throw RepositoryError.operationInProgress(state)
        }
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0 else {
            throw RepositoryError.identityNotConfigured
        }
        defer { git_signature_free(signature) }

        let index = try index()
        defer { git_index_free(index) }
        var treeID = git_oid()
        try check(git_index_write_tree(&treeID, index))
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &treeID))
        defer { git_tree_free(tree) }

        var parents: [OpaquePointer?] = []
        defer { parents.forEach { git_commit_free($0) } }
        if let head = try headCommit() {
            parents.append(head)
        }
        for id in try mergeHeads() {
            parents.append(try lookupCommit(id))
        }

        let text = message.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        var id = git_oid()
        try check(git_commit_create(
            &id, pointer, "HEAD", signature, signature, nil, text, tree, parents.count, &parents
        ))
        try check(git_repository_state_cleanup(pointer))
        return OID(id)
    }

    private func index() throws -> OpaquePointer? {
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        // Pick up changes another git made since this repository was opened.
        try check(git_index_read(index, 0))
        return index
    }

    /// The commits being merged into `HEAD`, while a merge is under way.
    private func mergeHeads() throws -> [OID] {
        let collected = MergeHeads()
        let code = git_repository_mergehead_foreach(pointer, { id, payload in
            guard let id, let payload else { return 0 }
            Unmanaged<MergeHeads>.fromOpaque(payload).takeUnretainedValue().ids.append(OID(id))
            return 0
        }, Unmanaged.passUnretained(collected).toOpaque())
        if code == GIT_ENOTFOUND.rawValue { return [] }
        try check(code)
        return collected.ids
    }

    private final class MergeHeads {
        var ids: [OID] = []
    }
}

extension StatusEntry {
    init?(_ entry: git_status_entry) {
        let status = entry.status.rawValue
        let staged = entry.head_to_index?.pointee
        let unstaged = entry.index_to_workdir?.pointee
        guard let path = (unstaged?.new_file.path ?? staged?.new_file.path).map({ String(cString: $0) }) else {
            return nil
        }

        func change(_ pairs: [(git_status_t, FileChange)]) -> FileChange? {
            pairs.first { status & $0.0.rawValue != 0 }?.1
        }
        self.init(
            path: path,
            originalPath: status & GIT_STATUS_INDEX_RENAMED.rawValue != 0
                ? staged?.old_file.path.map { String(cString: $0) } : nil,
            staged: change([
                (GIT_STATUS_INDEX_NEW, .added),
                (GIT_STATUS_INDEX_RENAMED, .renamed),
                (GIT_STATUS_INDEX_MODIFIED, .modified),
                (GIT_STATUS_INDEX_DELETED, .deleted),
                (GIT_STATUS_INDEX_TYPECHANGE, .typeChanged)
            ]),
            unstaged: change([
                (GIT_STATUS_CONFLICTED, .conflicted),
                (GIT_STATUS_WT_NEW, .untracked),
                (GIT_STATUS_WT_MODIFIED, .modified),
                (GIT_STATUS_WT_DELETED, .deleted),
                (GIT_STATUS_WT_TYPECHANGE, .typeChanged),
                (GIT_STATUS_WT_RENAMED, .renamed)
            ])
        )
    }
}
