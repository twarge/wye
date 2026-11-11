import Clibgit2
import Foundation

/// Why a worktree operation was refused.
public enum WorktreeError: Error, Hashable, Sendable, LocalizedError {
    /// The branch is checked out in the worktree at `path`; git allows a
    /// branch in one worktree at a time.
    case branchCheckedOut(branch: String, path: String)
    case notFound(String)
    /// The operation does not apply to the main worktree.
    case mainWorktree
    case locked(name: String, reason: String?)
    case hasLocalChanges(path: String)
    case pathExists(String)
    case invalidName(String)
    /// The app may not look at the worktree's folder.
    case unreachable(path: String)

    public var errorDescription: String? {
        switch self {
        case .branchCheckedOut(let branch, let path):
            "“\(branch)” is already checked out in the worktree at \(path). A branch can be checked out in only one worktree at a time."
        case .notFound(let name):
            "There is no worktree “\(name)”."
        case .mainWorktree:
            "The main worktree holds the repository itself, so it cannot be moved or removed."
        case .locked(let name, let reason):
            "The worktree “\(name)” is locked\(reason.map { ": \($0)" } ?? ""). Unlock it first."
        case .hasLocalChanges(let path):
            "The worktree at \(path) has uncommitted changes or untracked files."
        case .pathExists(let path):
            "Something is already at \(path)."
        case .invalidName(let name):
            "“\(name)” cannot name a worktree."
        case .unreachable(let path):
            "Twig has no access to the folder at \(path). Open the worktree and choose its folder to give Twig access."
        }
    }
}

/// What a new worktree checks out.
public enum WorktreeTarget: Hashable, Sendable {
    /// A local branch, by full reference name, that no other worktree has.
    case branch(String)
    /// A new branch of that short name, started at a commit.
    case newBranch(String, at: OID)
    /// A commit, with `HEAD` detached.
    case detached(OID)
}

extension Repository {
    // MARK: Listing

    /// The main worktree and every linked one, as `git worktree list` gives
    /// them, with the one this repository was opened as marked current.
    public func worktrees() throws -> [Worktree] {
        let current = git_repository_workdir(pointer).map { Self.realPath(String(cString: $0)) }
        var result: [Worktree] = []
        let common = String(cString: git_repository_commondir(pointer))

        if let main = mainWorktree(commonDirectory: common) {
            var main = main
            main.isCurrent = current == Self.realPath(main.path)
            result.append(main)
        }

        var names = git_strarray()
        try check(git_worktree_list(&names, pointer))
        defer { git_strarray_dispose(&names) }
        for name in strings(in: names) {
            var worktree: OpaquePointer?
            guard git_worktree_lookup(&worktree, pointer, name) == 0 else { continue }
            defer { git_worktree_free(worktree) }
            var reason = git_buf()
            defer { git_buf_dispose(&reason) }
            let locked = git_worktree_is_locked(&reason, worktree) > 0
            let path = String(cString: git_worktree_path(worktree)).trimmingTrailingSlashes
            var item = Worktree(name: name, path: path, isLocked: locked)
            item.lockReason = locked ? reason.ptr.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank : nil
            item.head = head(inGitDirectory: URL(filePath: common).appending(path: "worktrees/\(name)"))
            switch Self.folderState(path) {
            case .present: item.isMissing = git_worktree_validate(worktree) != 0
            case .missing: item.isMissing = true
            case .unreachable: item.isReachable = false
            }
            item.isCurrent = current == Self.realPath(path)
            result.append(item)
        }
        return result
    }

    /// The main worktree: the folder the common git directory belongs to.
    private func mainWorktree(commonDirectory: String) -> Worktree? {
        if git_repository_is_worktree(pointer) == 0 {
            guard let workdir = git_repository_workdir(pointer) else { return nil }
            var main = Worktree(name: "", path: String(cString: workdir).trimmingTrailingSlashes, isLocked: false)
            main.isMain = true
            main.head = try? head()
            return main
        }
        var repository: OpaquePointer?
        guard git_repository_open_ext(&repository, commonDirectory, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil) == 0
        else { return nil }
        defer { git_repository_free(repository) }
        guard let workdir = git_repository_workdir(repository) else { return nil }
        var main = Worktree(name: "", path: String(cString: workdir).trimmingTrailingSlashes, isLocked: false)
        main.isMain = true
        main.head = head(inGitDirectory: URL(filePath: commonDirectory))
        return main
    }

    /// A worktree's `HEAD`, read from its git directory.
    private func head(inGitDirectory directory: URL) -> Head? {
        guard let text = try? String(contentsOf: directory.appending(path: "HEAD"), encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let name = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            var id = git_oid()
            if git_reference_name_to_id(&id, pointer, name) == 0 {
                return .branch(name: name, target: OID(id))
            }
            return .unborn(name: name)
        }
        return OID(hex: line).map(Head.detached)
    }

    /// Where another worktree than this one has a local branch, by full
    /// reference name, checked out.
    public func worktreeHolding(branch: String) throws -> Worktree? {
        try worktrees().first { !$0.isCurrent && $0.head?.branchName == branch }
    }

    private enum FolderState {
        case present, missing, unreachable
    }

    /// Whether a folder is there, gone, or out of the app's reach. A
    /// sandbox refuses to look at a folder the user has not granted, which
    /// says nothing about whether it exists.
    private static func folderState(_ path: String) -> FolderState {
        var information = stat()
        if stat(path, &information) == 0 { return .present }
        return errno == ENOENT || errno == ENOTDIR ? .missing : .unreachable
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return URL(filePath: path).standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlashes
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Adding

    /// Adds a linked worktree in a new folder at `url`, as
    /// `git worktree add` does, checking out `target`. Its name is the
    /// folder's, made unique. A branch another worktree has is refused,
    /// naming where. Returns the new worktree.
    @discardableResult
    public func addWorktree(at url: URL, target: WorktreeTarget, lockReason: String? = nil) throws -> Worktree {
        let path = url.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlashes
        guard !FileManager.default.fileExists(atPath: path) else { throw WorktreeError.pathExists(path) }
        let name = try uniqueWorktreeName(for: url.lastPathComponent)

        var temporaryBranch: String?
        var createdBranch: String?
        let reference: String
        switch target {
        case .branch(let branch):
            if let holder = try worktrees().first(where: { $0.head?.branchName == branch }) {
                throw WorktreeError.branchCheckedOut(branch: Self.shortBranchName(branch), path: holder.path)
            }
            reference = branch
        case .newBranch(let branch, let commit):
            reference = try createBranch(named: branch, at: commit)
            createdBranch = reference
        case .detached(let commit):
            // libgit2 adds a worktree only on a branch; one made for the
            // purpose is dropped once HEAD is detached.
            reference = try createBranch(named: "twig-worktree-\(UUID().uuidString.prefix(8))", at: commit)
            temporaryBranch = reference
        }

        do {
            var branch: OpaquePointer?
            try check(git_reference_lookup(&branch, pointer, reference))
            defer { git_reference_free(branch) }
            var options = git_worktree_add_options()
            try check(git_worktree_add_options_init(&options, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION)))
            options.ref = branch
            options.lock = lockReason == nil ? 0 : 1
            options.checkout_options.checkout_strategy = temporaryBranch == nil
                ? GIT_CHECKOUT_SAFE.rawValue : GIT_CHECKOUT_NONE.rawValue
            var worktree: OpaquePointer?
            try check(git_worktree_add(&worktree, pointer, name, path, &options))
            defer { git_worktree_free(worktree) }

            if case .detached(let commit) = target {
                var repository: OpaquePointer?
                try check(git_repository_open_from_worktree(&repository, worktree))
                defer { git_repository_free(repository) }
                var id = commit.raw
                try check(git_repository_set_head_detached(repository, &id))
                var checkout = git_checkout_options()
                try check(git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
                checkout.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
                try check(git_checkout_head(repository, &checkout))
            }
            if let lockReason, !lockReason.isEmpty {
                try check(git_worktree_unlock(worktree))
                try check(git_worktree_lock(worktree, lockReason))
            }
            if let temporaryBranch { try? deleteBranch(temporaryBranch, force: true) }
        } catch {
            for branch in [temporaryBranch, createdBranch].compactMap(\.self) {
                try? deleteBranch(branch, force: true)
            }
            try? FileManager.default.removeItem(atPath: path)
            let common = URL(filePath: String(cString: git_repository_commondir(pointer)))
            try? FileManager.default.removeItem(at: common.appending(path: "worktrees/\(name)"))
            throw error
        }
        guard let added = try worktrees().first(where: { $0.name == name }) else { throw WorktreeError.notFound(name) }
        return added
    }

    /// The folder's name, or with a number after it when a worktree has it,
    /// as git chooses.
    private func uniqueWorktreeName(for folder: String) throws -> String {
        let base = folder.replacingOccurrences(of: " ", with: "-")
        guard !base.isEmpty, !base.hasPrefix("."), !base.contains("/") else { throw WorktreeError.invalidName(folder) }
        let common = URL(filePath: String(cString: git_repository_commondir(pointer)))
        var name = base
        var number = 1
        while FileManager.default.fileExists(atPath: common.appending(path: "worktrees/\(name)").path(percentEncoded: false)) {
            name = "\(base)\(number)"
            number += 1
        }
        return name
    }

    private static func shortBranchName(_ reference: String) -> String {
        reference.hasPrefix("refs/heads/") ? String(reference.dropFirst("refs/heads/".count)) : reference
    }

    // MARK: Locking

    /// Locks a linked worktree, so it is not pruned when its folder is away
    /// (on a removable disk, say), with an optional reason.
    public func lockWorktree(_ name: String, reason: String? = nil) throws {
        let worktree = try lookupWorktree(name)
        defer { git_worktree_free(worktree) }
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        try check(git_worktree_lock(worktree, reason?.isEmpty == false ? reason : nil))
    }

    public func unlockWorktree(_ name: String) throws {
        let worktree = try lookupWorktree(name)
        defer { git_worktree_free(worktree) }
        try check(git_worktree_unlock(worktree))
    }

    private func lookupWorktree(_ name: String) throws -> OpaquePointer {
        guard !name.isEmpty else { throw WorktreeError.mainWorktree }
        var worktree: OpaquePointer?
        let code = git_worktree_lookup(&worktree, pointer, name)
        if code == GIT_ENOTFOUND.rawValue { throw WorktreeError.notFound(name) }
        try check(code)
        return worktree!
    }

    // MARK: Moving and removing

    /// Moves a linked worktree's folder to `url`, which must not exist, and
    /// updates the links between it and the repository, as
    /// `git worktree move` does. A locked worktree is refused.
    public func moveWorktree(_ name: String, to url: URL) throws {
        guard let item = try worktrees().first(where: { $0.name == name }), !item.isMain else {
            throw name.isEmpty ? WorktreeError.mainWorktree : WorktreeError.notFound(name)
        }
        guard !item.isLocked else { throw WorktreeError.locked(name: name, reason: item.lockReason) }
        guard item.isReachable else { throw WorktreeError.unreachable(path: item.path) }
        let destination = url.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlashes
        guard !FileManager.default.fileExists(atPath: destination) else { throw WorktreeError.pathExists(destination) }

        let gitDirectory = URL(filePath: String(cString: git_repository_commondir(pointer)))
            .appending(path: "worktrees/\(name)", directoryHint: .isDirectory)
        try FileManager.default.moveItem(atPath: item.path, toPath: destination)
        let newURL = URL(filePath: destination, directoryHint: .isDirectory)
        // The worktree's `.git` file names its git directory; a relative
        // one has to be worked out again from the new place.
        let dotGit = newURL.appending(path: ".git")
        if let text = try? String(contentsOf: dotGit, encoding: .utf8),
           let target = text.split(whereSeparator: \.isNewline).first?.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespaces), !target.hasPrefix("/") {
            try "gitdir: \(Self.relativePath(from: newURL, to: gitDirectory))\n"
                .write(to: dotGit, atomically: true, encoding: .utf8)
        }
        let link = gitDirectory.appending(path: "gitdir")
        let old = (try? String(contentsOf: link, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = old.hasPrefix("/") || old.isEmpty
            ? Self.realPath(destination) + "/.git"
            : Self.relativePath(from: gitDirectory, to: newURL.appending(path: ".git"))
        try (value + "\n").write(to: link, atomically: true, encoding: .utf8)
    }

    /// Removes a linked worktree's folder and its entry, as
    /// `git worktree remove` does. One with uncommitted changes or untracked
    /// files is refused unless `force` is set; a locked one is refused.
    public func removeWorktree(_ name: String, force: Bool = false) throws {
        guard let item = try worktrees().first(where: { $0.name == name }), !item.isMain else {
            throw name.isEmpty ? WorktreeError.mainWorktree : WorktreeError.notFound(name)
        }
        guard !item.isLocked else { throw WorktreeError.locked(name: name, reason: item.lockReason) }
        guard item.isReachable else { throw WorktreeError.unreachable(path: item.path) }
        let worktree = try lookupWorktree(name)
        defer { git_worktree_free(worktree) }
        if FileManager.default.fileExists(atPath: item.path) {
            if !force, try worktreeHasChanges(worktree) {
                throw WorktreeError.hasLocalChanges(path: item.path)
            }
            try FileManager.default.removeItem(atPath: item.path)
        }
        var options = git_worktree_prune_options()
        try check(git_worktree_prune_options_init(&options, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION)))
        options.flags = GIT_WORKTREE_PRUNE_VALID.rawValue
        try check(git_worktree_prune(worktree, &options))
    }

    private func worktreeHasChanges(_ worktree: OpaquePointer?) throws -> Bool {
        var repository: OpaquePointer?
        guard git_repository_open_from_worktree(&repository, worktree) == 0 else { return false }
        defer { git_repository_free(repository) }
        var options = git_status_options()
        try check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
        var list: OpaquePointer?
        try check(git_status_list_new(&list, repository, &options))
        defer { git_status_list_free(list) }
        return git_status_list_entrycount(list) > 0
    }

    /// Removes the entries of linked worktrees whose folders are gone and
    /// that are not locked, as `git worktree prune` does. Returns their names.
    @discardableResult
    public func pruneWorktrees() throws -> [String] {
        var pruned: [String] = []
        for item in try worktrees() where item.isPrunable {
            let worktree = try lookupWorktree(item.name)
            defer { git_worktree_free(worktree) }
            var options = git_worktree_prune_options()
            try check(git_worktree_prune_options_init(&options, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION)))
            guard git_worktree_is_prunable(worktree, &options) > 0 else { continue }
            try check(git_worktree_prune(worktree, &options))
            pruned.append(item.name)
        }
        return pruned
    }

    /// Opens a linked or main worktree as a repository of its own.
    public func openWorktree(_ item: Worktree) throws -> Repository {
        try Repository(at: URL(filePath: item.path, directoryHint: .isDirectory))
    }
}

extension String {
    fileprivate var trimmingTrailingSlashes: String {
        var path = self
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    fileprivate var nilIfBlank: String? { isEmpty ? nil : self }
}
