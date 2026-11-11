import Clibgit2
import Foundation

/// Why a submodule operation was refused.
public enum SubmoduleError: Error, Hashable, Sendable, LocalizedError {
    case notFound(String)
    /// It is not initialized, and the operation was told not to initialize it.
    case notInitialized(String)
    /// It is not cloned, so there is no repository inside it to work in.
    case notCloned(String)
    /// It has uncommitted changes or untracked files that removing it would lose.
    case hasLocalChanges(String)
    /// Something is already at the path.
    case pathTaken(String)
    case invalidPath(String)
    /// `.gitmodules` has no URL for it.
    case noURL(String)
    /// The branch asked for is not on the remote.
    case branchNotFound(String)
    case bareRepository

    public var errorDescription: String? {
        switch self {
        case .notFound(let name):
            "There is no submodule “\(name)”."
        case .notInitialized(let path):
            "The submodule “\(path)” is not initialized. Initialize it first."
        case .notCloned(let path):
            "The submodule “\(path)” is not cloned yet. Update it first."
        case .hasLocalChanges(let path):
            "The submodule “\(path)” has uncommitted changes or untracked files."
        case .pathTaken(let path):
            "Something is already at “\(path)”."
        case .invalidPath(let path):
            "“\(path)” is not a path inside the working copy."
        case .noURL(let path):
            "The submodule “\(path)” has no URL in .gitmodules."
        case .branchNotFound(let branch):
            "The remote has no branch “\(branch)”."
        case .bareRepository:
            "A bare repository has no working copy for submodules."
        }
    }
}

/// How a submodule's recorded commit changed in a diff, and the commits in
/// between when the submodule is checked out here to read them from.
public struct SubmoduleChange: Hashable, Sendable {
    /// The recorded commit before; `nil` when the submodule was added.
    public var oldID: OID?
    /// The recorded commit after; `nil` when it was removed.
    public var newID: OID?
    /// Commits between the two, newest first, as `git diff --submodule=log`
    /// lists them: those only the new side has, then those only the old one
    /// has. Empty when the submodule could not be read.
    public var commits: [Commit] = []
    /// Whether `commits` was cut short.
    public var isTruncated = false
    /// Whether the submodule's repository is here to read commits from.
    public var isAvailable = false
    /// For a working copy diff: what is changed inside the submodule.
    public var changes: SubmoduleChanges = []

    public struct Commit: Identifiable, Hashable, Sendable {
        public var id: OID
        public var summary: String
        /// Whether the new side has it; otherwise only the old side does,
        /// and the change takes it away.
        public var isAdded: Bool
    }

    /// Most commits listed in a diff, each way.
    public static let commitLimit = 50
}

extension Repository {
    // MARK: Listing

    /// Every submodule, with where it stands.
    public func submodules() throws -> [Submodule] {
        guard !isBare else { return [] }
        let collected = Collector<Submodule>()
        let code = git_submodule_foreach(pointer, { submodule, name, payload in
            guard let submodule, let name, let payload else { return 0 }
            let collected = Unmanaged<Collector<Submodule>>.fromOpaque(payload).takeUnretainedValue()
            var item = Submodule(
                name: String(cString: name),
                path: String(cString: git_submodule_path(submodule)),
                url: git_submodule_url(submodule).map { String(cString: $0) },
                headID: git_submodule_head_id(submodule).map { OID($0) }
            )
            item.indexID = git_submodule_index_id(submodule).map { OID($0) }
            item.checkedOutID = git_submodule_wd_id(submodule).map { OID($0) }
            item.branch = git_submodule_branch(submodule).map { String(cString: $0) }
            collected.items.append(item)
            return 0
        }, Unmanaged.passUnretained(collected).toOpaque())
        try check(code)

        let configured = configuredSubmoduleURLs()
        return collected.items.map { item in
            var item = item
            let flags = submoduleStatusFlags(item.name)
            item.resolvedURL = configured[item.name] ?? item.url.map(resolveSubmoduleURL)
            item.changes = Self.changes(from: flags)
            item.status = Self.state(from: flags, initialized: configured[item.name] != nil, changes: item.changes)
            return item
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func state(from flags: UInt32, initialized: Bool, changes: SubmoduleChanges) -> SubmoduleState {
        func has(_ flag: git_submodule_status_t) -> Bool { flags & flag.rawValue != 0 }
        if !initialized && !has(GIT_SUBMODULE_STATUS_IN_WD) { return .notInitialized }
        if has(GIT_SUBMODULE_STATUS_WD_DELETED) { return .missing }
        if has(GIT_SUBMODULE_STATUS_WD_UNINITIALIZED) || !has(GIT_SUBMODULE_STATUS_IN_WD) {
            return initialized ? .notCloned : .notInitialized
        }
        if !initialized { return .notInitialized }
        if changes.contains(.newCommits) { return .differentCommit }
        if !changes.isEmpty { return .modifiedContent }
        return .upToDate
    }

    static func changes(from flags: UInt32) -> SubmoduleChanges {
        var changes: SubmoduleChanges = []
        if flags & GIT_SUBMODULE_STATUS_WD_MODIFIED.rawValue != 0 { changes.insert(.newCommits) }
        if flags & (GIT_SUBMODULE_STATUS_WD_INDEX_MODIFIED.rawValue | GIT_SUBMODULE_STATUS_WD_WD_MODIFIED.rawValue) != 0 {
            changes.insert(.modifiedContent)
        }
        if flags & GIT_SUBMODULE_STATUS_WD_UNTRACKED.rawValue != 0 { changes.insert(.untrackedContent) }
        return changes
    }

    func submoduleStatusFlags(_ name: String) -> UInt32 {
        var flags: UInt32 = 0
        guard git_submodule_status(&flags, pointer, name, GIT_SUBMODULE_IGNORE_NONE) == 0 else { return 0 }
        return flags
    }

    /// `submodule.<name>.url` from the superproject's own configuration,
    /// which `init` writes: being there is what being initialized means.
    private func configuredSubmoduleURLs() -> [String: String] {
        var configuration: OpaquePointer?
        guard git_repository_config_snapshot(&configuration, pointer) == 0 else { return [:] }
        defer { git_config_free(configuration) }
        var iterator: OpaquePointer?
        guard git_config_iterator_glob_new(&iterator, configuration, #"^submodule\..*\.url$"#) == 0 else { return [:] }
        defer { git_config_iterator_free(iterator) }
        var urls: [String: String] = [:]
        var entry: UnsafeMutablePointer<git_config_entry>?
        while git_config_next(&entry, iterator) == 0, let entry {
            let key = String(cString: entry.pointee.name)
            let name = String(key.dropFirst("submodule.".count).dropLast(".url".count))
            urls[name] = entry.pointee.value.map { String(cString: $0) }
        }
        return urls
    }

    /// The submodules to act on: those named, or all of them.
    private func targets(_ names: [String]?) throws -> [Submodule] {
        let all = try submodules()
        guard let names else { return all }
        return try names.map { name in
            guard let found = all.first(where: { $0.name == name }) else { throw SubmoduleError.notFound(name) }
            return found
        }
    }

    private func lookupSubmodule(_ name: String) throws -> OpaquePointer {
        var submodule: OpaquePointer?
        let code = git_submodule_lookup(&submodule, pointer, name)
        if code == GIT_ENOTFOUND.rawValue { throw SubmoduleError.notFound(name) }
        try check(code)
        return submodule!
    }

    private var workingDirectory: URL {
        get throws {
            guard let path = git_repository_workdir(pointer) else { throw SubmoduleError.bareRepository }
            return URL(filePath: String(cString: path), directoryHint: .isDirectory)
        }
    }

    /// Opens a cloned submodule as a repository of its own.
    public func openSubmodule(_ name: String) throws -> Repository {
        let submodule = try lookupSubmodule(name)
        defer { git_submodule_free(submodule) }
        let path = String(cString: git_submodule_path(submodule))
        let url = try workingDirectory.appending(path: path, directoryHint: .isDirectory)
        guard Repository.exists(at: url) else { throw SubmoduleError.notCloned(path) }
        return try Repository(at: url)
    }

    // MARK: URLs

    /// A submodule URL as git reads it: one starting `./` or `../` is
    /// relative to the superproject's default remote (the current branch's
    /// upstream remote, otherwise `origin`), or to the superproject's own
    /// folder when it has no remote. Anything else is used as it is.
    public func resolveSubmoduleURL(_ url: String) -> String {
        guard url.hasPrefix("./") || url.hasPrefix("../") else { return url }
        var base = defaultSubmoduleRemoteURL() ?? ((try? workingDirectory.path(percentEncoded: false)) ?? ".")
        // A remote given as a relative local path is itself relative to the
        // superproject's folder.
        if let relative = Self.relativeLocalPath(in: base), let root = try? workingDirectory {
            base = root.appending(path: relative).standardizedFileURL.path(percentEncoded: false)
        }
        return Self.relativeURL(url, base: base)
    }

    /// git's `relative_url`: each `../` takes a component off the base, by
    /// `/` or, in an scp-like address, the `:` before its path.
    public static func relativeURL(_ url: String, base: String) -> String {
        var remote = base
        while remote.count > 1, remote.hasSuffix("/") { remote.removeLast() }
        var rest = Substring(url)
        var separator = "/"
        while true {
            if rest.hasPrefix("../") {
                rest = rest.dropFirst(3)
                if let slash = remote.lastIndex(of: "/"), !(remote.hasSuffix(":/") || remote.hasSuffix("//")) {
                    remote = String(remote[..<slash])
                } else if let colon = remote.lastIndex(of: ":") {
                    remote = String(remote[..<colon])
                    separator = ":"
                } else {
                    remote = "."
                }
            } else if rest.hasPrefix("./") {
                rest = rest.dropFirst(2)
            } else {
                break
            }
        }
        var tail = String(rest)
        while tail.hasSuffix("/") { tail.removeLast() }
        return tail.isEmpty ? remote : remote + separator + tail
    }

    private func defaultSubmoduleRemoteURL() -> String? {
        var configuration: OpaquePointer?
        guard git_repository_config_snapshot(&configuration, pointer) == 0 else { return nil }
        defer { git_config_free(configuration) }
        var remoteName: String?
        if case .branch(let branch, _)? = try? head() {
            remoteName = GitEnvironment.string(
                for: "branch.\(branch.dropFirst("refs/heads/".count)).remote", in: configuration
            )
        }
        for name in [remoteName, "origin"].compactMap(\.self) {
            if let url = GitEnvironment.string(for: "remote.\(name).url", in: configuration) { return url }
        }
        return nil
    }

    // MARK: Initialize and synchronize

    /// Copies submodules' URLs from `.gitmodules` into the configuration,
    /// as `git submodule init` does: the named ones, or all. One already
    /// initialized keeps its URL.
    public func initializeSubmodules(_ names: [String]? = nil) throws {
        for submodule in try targets(names) where submodule.status == .notInitialized {
            try initialize(submodule)
        }
    }

    private func initialize(_ submodule: Submodule) throws {
        guard let url = submodule.url else { throw SubmoduleError.noURL(submodule.path) }
        try withConfiguration { configuration in
            try check(git_config_set_string(configuration, "submodule.\(submodule.name).url", resolveSubmoduleURL(url)))
            try check(git_config_set_bool(configuration, "submodule.\(submodule.name).active", 1))
        }
    }

    /// Copies `.gitmodules`' URLs into the configuration of initialized
    /// submodules and into the remote of the cloned ones, as
    /// `git submodule sync` does.
    public func synchronizeSubmodules(_ names: [String]? = nil) throws {
        for submodule in try targets(names) where submodule.status != .notInitialized {
            guard let url = submodule.url else { continue }
            let resolved = resolveSubmoduleURL(url)
            try withConfiguration { configuration in
                try check(git_config_set_string(configuration, "submodule.\(submodule.name).url", resolved))
            }
            guard let repository = try? openSubmodulePointer(submodule.path) else { continue }
            defer { git_repository_free(repository) }
            var configuration: OpaquePointer?
            try check(git_repository_config(&configuration, repository))
            defer { git_config_free(configuration) }
            var remote = "origin"
            var reference: OpaquePointer?
            if git_repository_head(&reference, repository) == 0, git_reference_is_branch(reference) != 0,
               let branch = String(validatingCString: git_reference_shorthand(reference)),
               let configured = GitEnvironment.string(for: "branch.\(branch).remote", in: configuration) {
                remote = configured
            }
            git_reference_free(reference)
            try check(git_config_set_string(configuration, "remote.\(remote).url", resolved))
        }
    }

    private func withConfiguration(_ body: (OpaquePointer?) throws -> Void) throws {
        var configuration: OpaquePointer?
        try check(git_repository_config(&configuration, pointer))
        defer { git_config_free(configuration) }
        try body(configuration)
    }

    private func openSubmodulePointer(_ path: String) throws -> OpaquePointer? {
        let url = try workingDirectory.appending(path: path)
        var repository: OpaquePointer?
        try check(git_repository_open_ext(&repository, url.path, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil))
        return repository
    }

    // MARK: Update and fetch

    /// Clones submodules that are not cloned yet and checks each out at the
    /// commit the superproject records, as `git submodule update` does: the
    /// named ones, or all. `initialize` initializes those that are not;
    /// `recursive` goes on into the submodules' own submodules; `fetch`
    /// fetches each one first, rather than only when the recorded commit is
    /// missing.
    public func updateSubmodules(
        _ names: [String]? = nil,
        initialize: Bool = true,
        recursive: Bool = false,
        fetch: Bool = false,
        credentials: (any CredentialProvider)? = nil,
        transfer: Transfer? = nil
    ) async throws {
        defer { transfer?.finish() }
        try await updateSubmodulesContinuing(
            names, initialize: initialize, recursive: recursive, fetch: fetch, credentials: credentials, transfer: transfer
        )
    }

    /// The update, leaving the transfer open for the submodules' own.
    func updateSubmodulesContinuing(
        _ names: [String]?, initialize: Bool, recursive: Bool, fetch: Bool,
        credentials: (any CredentialProvider)?, transfer: Transfer?
    ) async throws {
        for submodule in try targets(names) {
            if transfer?.isCancelled == true || Task.isCancelled { throw CancellationError() }
            if submodule.status == .notInitialized {
                guard initialize else { throw SubmoduleError.notInitialized(submodule.path) }
                try self.initialize(submodule)
            }
            if fetch, submodule.status != .notCloned, submodule.status != .notInitialized,
               let inner = try? openSubmodule(submodule.name) {
                try await inner.fetchForSubmodule(credentials: credentials, transfer: transfer)
            }
            try update(submodule.name, credentials: credentials, transfer: transfer)
            if recursive {
                let inner = try openSubmodule(submodule.name)
                try await inner.updateSubmodulesContinuing(
                    nil, initialize: true, recursive: true, fetch: fetch, credentials: credentials, transfer: transfer
                )
            }
        }
    }

    private func update(_ name: String, credentials: (any CredentialProvider)?, transfer: Transfer?) throws {
        let submodule = try lookupSubmodule(name)
        defer { git_submodule_free(submodule) }
        let session = RemoteSession(transfer: transfer, credentials: credentials)
        session.report(TransferProgress(phase: .connecting))
        var options = git_submodule_update_options()
        try check(git_submodule_update_options_init(&options, UInt32(GIT_SUBMODULE_UPDATE_OPTIONS_VERSION)))
        options.fetch_opts.callbacks = session.callbacks()
        options.checkout_opts = try session.checkoutOptions()
        options.allow_fetch = 1
        try withExtendedLifetime(session) {
            try session.check(git_submodule_update(submodule, 0, &options))
        }
    }

    /// Fetches every remote of this repository, as a submodule of another,
    /// keeping the transfer open.
    func fetchForSubmodule(credentials: (any CredentialProvider)?, transfer: Transfer?) throws {
        do {
            try fetchRemotes(nil, prune: false, tags: .automatic, session: RemoteSession(transfer: transfer, credentials: credentials))
        } catch RemoteError.noRemotes {
            // Nothing to fetch from.
        }
    }

    /// Fetches the named cloned submodules, or all of them, from their
    /// remotes, as `git submodule foreach git fetch` does.
    public func fetchSubmodules(
        _ names: [String]? = nil, credentials: (any CredentialProvider)? = nil, transfer: Transfer? = nil
    ) async throws {
        defer { transfer?.finish() }
        for submodule in try targets(names) {
            if transfer?.isCancelled == true || Task.isCancelled { throw CancellationError() }
            guard let inner = try? openSubmodule(submodule.name) else {
                if names != nil { throw SubmoduleError.notCloned(submodule.path) }
                continue
            }
            try await inner.fetchForSubmodule(credentials: credentials, transfer: transfer)
        }
    }

    // MARK: Checking out inside a submodule

    /// Checks out a revision inside a submodule: a local branch by name,
    /// otherwise anything git can name a commit by, detached. The
    /// superproject then shows the submodule as changed, to stage.
    public func checkOutSubmodule(_ name: String, revision: String) async throws {
        let inner = try openSubmodule(name)
        try await inner.checkOutRevision(revision)
    }

    func checkOutRevision(_ revision: String) throws {
        let trimmed = revision.trimmingCharacters(in: .whitespaces)
        let branch = trimmed.hasPrefix("refs/heads/") ? trimmed : "refs/heads/" + trimmed
        var reference: OpaquePointer?
        if git_reference_lookup(&reference, pointer, branch) == 0 {
            git_reference_free(reference)
            try checkOut(branch: branch)
            return
        }
        var object: OpaquePointer?
        try check(git_revparse_single(&object, pointer, trimmed))
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        try check(git_object_peel(&commit, object, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }
        try checkOut(commit: OID(git_object_id(commit)))
    }

    // MARK: Adding

    /// Adds a submodule: clones `url` into `path`, keeping its repository
    /// under `.git/modules`, and stages `.gitmodules` and the new entry,
    /// as `git submodule add` does. A relative URL is recorded as given and
    /// cloned from what it resolves to. `branch` checks that branch out and
    /// records it. A clone that fails or is cancelled leaves nothing
    /// behind. Returns the submodule's name.
    @discardableResult
    public func addSubmodule(
        url: String, path rawPath: String, branch: String? = nil,
        credentials: (any CredentialProvider)? = nil, transfer: Transfer? = nil
    ) throws -> String {
        defer { transfer?.finish() }
        let root = try workingDirectory
        let path = try Self.validSubmodulePath(rawPath)
        let folder = root.appending(path: path, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)),
           (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.isEmpty == false {
            throw SubmoduleError.pathTaken(path)
        }
        let given = url.trimmingCharacters(in: .whitespaces)
        let resolved = resolveSubmoduleURL(given)
        let branch = branch?.trimmingCharacters(in: .whitespaces).nilIfEmpty

        let modulesFile = root.appending(path: ".gitmodules")
        let savedModules = try? Data(contentsOf: modulesFile)
        let folderExisted = FileManager.default.fileExists(atPath: folder.path(percentEncoded: false))
        let session = RemoteSession(transfer: transfer, credentials: credentials)
        if session.isCancelled { throw CancellationError() }
        session.report(TransferProgress(phase: .connecting))

        var submodule: OpaquePointer?
        var name = path
        do {
            try check(git_submodule_add_setup(&submodule, pointer, resolved, path, 1))
            name = String(cString: git_submodule_name(submodule))
            if let branch {
                try check(git_submodule_set_branch(pointer, name, branch))
            }
            var options = git_submodule_update_options()
            try check(git_submodule_update_options_init(&options, UInt32(GIT_SUBMODULE_UPDATE_OPTIONS_VERSION)))
            options.fetch_opts.callbacks = session.callbacks()
            options.checkout_opts = try session.checkoutOptions()
            var clone: OpaquePointer?
            try withExtendedLifetime(session) {
                try session.check(git_submodule_clone(&clone, submodule, &options))
            }
            defer { git_repository_free(clone) }
            if session.isCancelled { throw CancellationError() }
            if let branch, let clone {
                try Self.checkOutRemoteBranch(branch, in: clone)
            }
            if given != resolved {
                // `.gitmodules` keeps the URL as given, for everyone's clone.
                try check(git_submodule_set_url(pointer, name, given))
            }
            // The submodule was read before the clone; read it again so the
            // index gets the checked-out commit.
            try check(git_submodule_reload(submodule, 1))
            try check(git_submodule_add_finalize(submodule))
            git_submodule_free(submodule)
            return name
        } catch {
            git_submodule_free(submodule)
            undoAdd(name: name, folder: folder, folderExisted: folderExisted, modulesFile: modulesFile, saved: savedModules)
            throw error
        }
    }

    /// Takes away what a failed add left: its configuration, `.gitmodules`
    /// as it was, its folder and its repository.
    private func undoAdd(name: String, folder: URL, folderExisted: Bool, modulesFile: URL, saved: Data?) {
        try? removeConfigurationSection("submodule.\(name)", inFile: nil)
        if let saved {
            try? saved.write(to: modulesFile)
        } else {
            try? FileManager.default.removeItem(at: modulesFile)
        }
        if folderExisted {
            for child in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: child)
            }
        } else {
            try? FileManager.default.removeItem(at: folder)
        }
        try? FileManager.default.removeItem(at: modulesDirectory(for: name))
    }

    private func modulesDirectory(for name: String) -> URL {
        let common = URL(filePath: String(cString: git_repository_commondir(pointer)), directoryHint: .isDirectory)
        return common.appending(path: "modules").appending(path: name, directoryHint: .isDirectory)
    }

    /// Makes a fresh clone's checkout a local branch following the remote's
    /// branch of that name, as `git clone -b` does.
    private static func checkOutRemoteBranch(_ branch: String, in repository: OpaquePointer) throws {
        var remoteBranch: OpaquePointer?
        guard git_reference_lookup(&remoteBranch, repository, "refs/remotes/origin/\(branch)") == 0 else {
            throw SubmoduleError.branchNotFound(branch)
        }
        defer { git_reference_free(remoteBranch) }
        var commit: OpaquePointer?
        try check(git_reference_peel(&commit, remoteBranch, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }
        var local: OpaquePointer?
        let created = git_branch_create(&local, repository, branch, commit, 1)
        try check(created)
        defer { git_reference_free(local) }
        try check(git_branch_set_upstream(local, "origin/\(branch)"))
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try check(git_checkout_tree(repository, commit, &options))
        try check(git_repository_set_head(repository, "refs/heads/\(branch)"))
    }

    /// A path inside the working tree, without `./`, `..` or slashes at
    /// its ends.
    static func validSubmodulePath(_ path: String) throws -> String {
        let components = path.trimmingCharacters(in: .whitespaces).split(separator: "/").filter { $0 != "." }
        guard !components.isEmpty, !components.contains(".."), !components.contains(".git"),
              !path.trimmingCharacters(in: .whitespaces).hasPrefix("/") else {
            throw SubmoduleError.invalidPath(path)
        }
        return components.joined(separator: "/")
    }

    // MARK: Removing

    /// Removes a submodule completely: its configuration, its entry in the
    /// index and in `.gitmodules` (staged), its folder, and its repository
    /// under `.git/modules`. Refused when it has uncommitted changes or
    /// untracked files, unless `force` is set. Commits only it has are lost.
    public func removeSubmodule(_ name: String, force: Bool = false) throws {
        let root = try workingDirectory
        guard let submodule = try submodules().first(where: { $0.name == name }) else {
            throw SubmoduleError.notFound(name)
        }
        if !force, !submodule.changes.subtracting(.newCommits).isEmpty {
            throw SubmoduleError.hasLocalChanges(submodule.path)
        }
        // Its repository, wherever its `.git` file says it is.
        var gitDirectory = modulesDirectory(for: name)
        if let repository = try? openSubmodulePointer(submodule.path) {
            gitDirectory = URL(filePath: String(cString: git_repository_path(repository)), directoryHint: .isDirectory)
            git_repository_free(repository)
        }

        try removeConfigurationSection("submodule.\(name)", inFile: nil)
        let modulesFile = root.appending(path: ".gitmodules")
        try removeConfigurationSection("submodule.\(name)", inFile: modulesFile)

        let index = try submoduleIndex()
        defer { git_index_free(index) }
        let removed = git_index_remove_bypath(index, submodule.path)
        if removed != GIT_ENOTFOUND.rawValue { try check(removed) }
        if FileManager.default.fileExists(atPath: modulesFile.path(percentEncoded: false)) {
            try check(git_index_add_bypath(index, ".gitmodules"))
        }
        try check(git_index_write(index))

        let folder = root.appending(path: submodule.path, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: folder)
        }
        if FileManager.default.fileExists(atPath: gitDirectory.path(percentEncoded: false)),
           gitDirectory.standardizedFileURL.path.hasPrefix(modulesDirectory(for: "").standardizedFileURL.path) {
            try FileManager.default.removeItem(at: gitDirectory)
        }
    }

    /// Deletes every key of a configuration section, and then the section:
    /// in the repository's configuration, or in a file such as `.gitmodules`.
    private func removeConfigurationSection(_ section: String, inFile file: URL?) throws {
        if let file {
            guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        }
        var configuration: OpaquePointer?
        if let file {
            try check(git_config_open_ondisk(&configuration, file.path(percentEncoded: false)))
        } else {
            var full: OpaquePointer?
            try check(git_repository_config(&full, pointer))
            defer { git_config_free(full) }
            try check(git_config_open_level(&configuration, full, GIT_CONFIG_LEVEL_LOCAL))
        }
        defer { git_config_free(configuration) }
        var names: Set<String> = []
        var iterator: OpaquePointer?
        try check(git_config_iterator_glob_new(&iterator, configuration, "^" + NSRegularExpression.escapedPattern(for: section + ".")))
        var entry: UnsafeMutablePointer<git_config_entry>?
        while git_config_next(&entry, iterator) == 0, let entry {
            names.insert(String(cString: entry.pointee.name))
        }
        git_config_iterator_free(iterator)
        for name in names {
            try check(git_config_delete_multivar(configuration, name, ".*"))
        }
        if let file {
            try Self.dropEmptySection(section, in: file)
        }
    }

    /// libgit2 leaves a section's header when its last key goes; git takes
    /// it away.
    private static func dropEmptySection(_ section: String, in file: URL) throws {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let dot = section.firstIndex(of: ".")!
        let header = "[\(section[..<dot]) \"\(section[section.index(after: dot)...])\"]"
        var lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == header {
                let next = lines[(index + 1)...].firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if next == nil || lines[next!].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                    lines.remove(at: index)
                    continue
                }
            }
            index += 1
        }
        let result = lines.joined(separator: "\n")
        if result != text {
            try result.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func submoduleIndex() throws -> OpaquePointer? {
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        try check(git_index_read(index, 0))
        return index
    }

    // MARK: Moving and changing the URL

    /// Moves a submodule to another path in the working tree, as `git mv`
    /// does: its folder, its `.git` file and its repository's
    /// `core.worktree` follow, `.gitmodules` records the new path and the
    /// index the moved entry, both staged. Its name stays.
    public func moveSubmodule(_ name: String, to rawPath: String) throws {
        let root = try workingDirectory
        let newPath = try Self.validSubmodulePath(rawPath)
        guard let submodule = try submodules().first(where: { $0.name == name }) else {
            throw SubmoduleError.notFound(name)
        }
        guard newPath != submodule.path else { return }
        let source = root.appending(path: submodule.path, directoryHint: .isDirectory)
        let destination = root.appending(path: newPath, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw SubmoduleError.pathTaken(newPath)
        }

        let index = try submoduleIndex()
        defer { git_index_free(index) }
        guard let entry = git_index_get_bypath(index, submodule.path, 0)?.pointee else {
            throw SubmoduleError.notFound(name)
        }

        var gitDirectory: URL?
        if let repository = try? openSubmodulePointer(submodule.path) {
            gitDirectory = URL(filePath: String(cString: git_repository_path(repository)), directoryHint: .isDirectory)
            git_repository_free(repository)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        Self.removeEmptyParents(of: source, below: root)

        if let gitDirectory {
            let dotGit = destination.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path(percentEncoded: false), isDirectory: &isDirectory),
               !isDirectory.boolValue {
                let link = Self.relativePath(from: destination, to: gitDirectory)
                try "gitdir: \(link)\n".write(to: dotGit, atomically: true, encoding: .utf8)
            }
            var configuration: OpaquePointer?
            try check(git_config_open_ondisk(&configuration, gitDirectory.appending(path: "config").path(percentEncoded: false)))
            defer { git_config_free(configuration) }
            if GitEnvironment.string(for: "core.worktree", in: configuration) != nil {
                try check(git_config_set_string(configuration, "core.worktree", Self.relativePath(from: gitDirectory, to: destination)))
            }
        }

        var moved = git_index_entry()
        moved.mode = entry.mode
        moved.id = entry.id
        try check(git_index_remove_bypath(index, submodule.path))
        try newPath.withCString { path in
            moved.path = path
            try check(git_index_add(index, &moved))
        }
        let modulesFile = root.appending(path: ".gitmodules")
        var modules: OpaquePointer?
        try check(git_config_open_ondisk(&modules, modulesFile.path(percentEncoded: false)))
        defer { git_config_free(modules) }
        try check(git_config_set_string(modules, "submodule.\(name).path", newPath))
        try check(git_index_add_bypath(index, ".gitmodules"))
        try check(git_index_write(index))
    }

    /// Gives a submodule a new URL in `.gitmodules`, staged, and passes it
    /// on to the configuration and the clone, as `git submodule set-url`
    /// does.
    public func setSubmoduleURL(_ name: String, to url: String) throws {
        let url = url.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { throw SubmoduleError.noURL(name) }
        try check(git_submodule_set_url(pointer, name, url))
        let index = try submoduleIndex()
        defer { git_index_free(index) }
        try check(git_index_add_bypath(index, ".gitmodules"))
        try check(git_index_write(index))
        try synchronizeSubmodules([name])
    }

    /// The path from one folder to another, as `../..`-style components.
    static func relativePath(from base: URL, to target: URL) -> String {
        let from = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let to = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        let parts = Array(repeating: "..", count: from.count - common) + to[common...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    private static func removeEmptyParents(of folder: URL, below root: URL) {
        var parent = folder.deletingLastPathComponent().standardizedFileURL
        let top = root.standardizedFileURL.path
        while parent.path.count > top.count, parent.path.hasPrefix(top),
              (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
            parent = parent.deletingLastPathComponent()
        }
    }

    // MARK: Diffs

    /// Fills in the commits between the two sides of each submodule change,
    /// when the submodule is here to read them from. `workingCopy` adds what
    /// is changed inside it, for a diff against the working tree.
    func withSubmoduleCommits(_ files: [FileDiff], workingCopy: Bool = false) -> [FileDiff] {
        guard files.contains(where: { $0.submodule != nil }), let root = try? workingDirectory else { return files }
        let names = workingCopy ? submodulePathsToNames() : [:]
        return files.map { file in
            guard var change = file.submodule else { return file }
            var file = file
            var repository: OpaquePointer?
            let folder = root.appending(path: file.path)
            if git_repository_open_ext(&repository, folder.path, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil) == 0 {
                defer { git_repository_free(repository) }
                change.isAvailable = true
                let added = Self.commits(in: repository, from: change.newID, notIn: change.oldID)
                let removed = Self.commits(in: repository, from: change.oldID, notIn: change.newID)
                change.commits = added.commits.map { .init(id: $0.id, summary: $0.summary, isAdded: true) }
                    + removed.commits.map { .init(id: $0.id, summary: $0.summary, isAdded: false) }
                change.isTruncated = added.isTruncated || removed.isTruncated
                if added.missing || removed.missing { change.isAvailable = false }
            }
            if let name = names[file.path] {
                change.changes = Self.changes(from: submoduleStatusFlags(name))
            }
            file.submodule = change
            return file
        }
    }

    private func submodulePathsToNames() -> [String: String] {
        Dictionary(((try? submodules()) ?? []).map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private static func commits(
        in repository: OpaquePointer?, from tip: OID?, notIn base: OID?
    ) -> (commits: [(id: OID, summary: String)], isTruncated: Bool, missing: Bool) {
        guard let tip else { return ([], false, false) }
        var walk: OpaquePointer?
        guard git_revwalk_new(&walk, repository) == 0 else { return ([], false, true) }
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
        var tipID = tip.raw
        guard git_revwalk_push(walk, &tipID) == 0 else { return ([], false, true) }
        if let base {
            var baseID = base.raw
            guard git_revwalk_hide(walk, &baseID) == 0 else { return ([], false, true) }
        }
        var found: [(id: OID, summary: String)] = []
        var id = git_oid()
        while git_revwalk_next(&id, walk) == 0 {
            if found.count == SubmoduleChange.commitLimit { return (found, true, false) }
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, repository, &id) == 0 else { continue }
            found.append((OID(id), git_commit_summary(commit).map { String(cString: $0) } ?? ""))
            git_commit_free(commit)
        }
        return (found, false, false)
    }

    /// Marks each status entry that is a submodule with what changed in it.
    func withSubmoduleChanges(_ entries: [StatusEntry]) -> [StatusEntry] {
        let names = submodulePathsToNames()
        guard !names.isEmpty else { return entries }
        return entries.map { entry in
            guard let name = names[entry.path] else { return entry }
            var entry = entry
            entry.submodule = Self.changes(from: submoduleStatusFlags(name))
            return entry
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
