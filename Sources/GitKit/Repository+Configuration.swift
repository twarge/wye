import Clibgit2
import Foundation

/// One `name = value` line of a git configuration file. A multi-valued key
/// (such as `remote.origin.fetch`) is several entries with the same name,
/// in the file's order.
public struct ConfigurationEntry: Hashable, Sendable {
    /// The full key, as git lists it: section and variable lowercased,
    /// a subsection as written (`remote.origin.url`, `branch.Topic.merge`).
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The configuration files a repository reads, the ones Twig can show.
public enum ConfigurationLevel: Hashable, Sendable {
    /// The repository's own `.git/config`.
    case local
    /// The configuration for every repository: in Twig, the app's own file,
    /// never the one in the user's home folder.
    case global
}

extension Repository {
    // MARK: Reading

    /// Every entry in one configuration file, in the order git lists them.
    public func configurationEntries(at level: ConfigurationLevel = .local) throws -> [ConfigurationEntry] {
        try withConfiguration(level) { configuration in
            var iterator: OpaquePointer?
            try check(git_config_iterator_new(&iterator, configuration))
            defer { git_config_iterator_free(iterator) }
            var entries: [ConfigurationEntry] = []
            var entry: UnsafeMutablePointer<git_config_entry>?
            while true {
                let code = git_config_next(&entry, iterator)
                if code == GIT_ITEROVER.rawValue { break }
                try check(code)
                guard let entry, let name = entry.pointee.name else { continue }
                entries.append(ConfigurationEntry(
                    name: String(cString: name),
                    value: entry.pointee.value.map { String(cString: $0) } ?? ""
                ))
            }
            return entries
        }
    }

    /// The values of one key in the repository's own configuration, in order.
    public func configurationValues(_ name: String) throws -> [String] {
        let wanted = try Self.normalizedConfigurationName(name)
        return try configurationEntries(at: .local).filter { $0.name == wanted }.map(\.value)
    }

    /// The one value of a key in the repository's own configuration: the
    /// last, as git reads a key set more than once.
    public func configurationValue(_ name: String) throws -> String? {
        try configurationValues(name).last
    }

    // MARK: Writing

    /// Sets a key of the repository's own configuration to exactly these
    /// values, in this order, replacing whatever it had. No values removes
    /// the key.
    public func setConfigurationValues(_ values: [String], for name: String) throws {
        let name = try Self.normalizedConfigurationName(name)
        try withConfiguration(.local) { configuration in
            let code = git_config_delete_multivar(configuration, name, ".*")
            if code != GIT_ENOTFOUND.rawValue { try check(code) }
            if values.count == 1, let value = values.first {
                try check(git_config_set_string(configuration, name, value))
                return
            }
            for value in values {
                // A pattern that matches no value, so each call adds one.
                // Unlike setting a single value, libgit2 writes these as
                // given, so they are escaped here as git reads them.
                try check(git_config_set_multivar(configuration, name, "a^", Self.escapedConfigurationValue(value)))
            }
        }
    }

    /// A value as a configuration file holds it: backslashes, quotes,
    /// newlines, tabs and backspaces escaped.
    static func escapedConfigurationValue(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\u{8}": escaped += "\\b"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Sets a key of the repository's own configuration to one value, or
    /// removes it with `nil`.
    public func setConfigurationValue(_ value: String?, for name: String) throws {
        try setConfigurationValues(value.map { [$0] } ?? [], for: name)
    }

    /// Removes a key and all its values from the repository's own configuration.
    public func removeConfiguration(_ name: String) throws {
        try setConfigurationValues([], for: name)
    }

    /// Checks that a key is one git can store: `section.variable` or
    /// `section.subsection.variable`, returning it as git lists it.
    public static func normalizedConfigurationName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let normalized = ConfigurationKey.normalized(trimmed) else {
            throw ConfigurationError.invalidKey(trimmed)
        }
        return normalized
    }

    // MARK: Author

    /// `user.name` and `user.email` from the repository's own configuration,
    /// whichever of them it sets.
    public func localIdentity() throws -> (name: String?, email: String?) {
        let entries = try configurationEntries(at: .local)
        return (
            entries.last { $0.name == "user.name" }?.value,
            entries.last { $0.name == "user.email" }?.value
        )
    }

    /// Sets this repository's own author, or with `nil` makes it use the
    /// app's again.
    public func setLocalIdentity(_ identity: GitIdentity?) throws {
        try setConfigurationValue(identity?.name, for: "user.name")
        try setConfigurationValue(identity?.email, for: "user.email")
    }

    // MARK: Pull

    /// Writes how this repository pulls, as git reads it: `pull.ff = only`
    /// for fast-forward only, otherwise `pull.rebase`. `nil` removes both,
    /// leaving it to the app's setting.
    public func setConfiguredPullMode(_ mode: PullMode?) throws {
        switch mode {
        case nil:
            try setConfigurationValue(nil, for: "pull.rebase")
            try setConfigurationValue(nil, for: "pull.ff")
        case .merge:
            try setConfigurationValue("false", for: "pull.rebase")
            try setConfigurationValue(nil, for: "pull.ff")
        case .rebase:
            try setConfigurationValue("true", for: "pull.rebase")
            try setConfigurationValue(nil, for: "pull.ff")
        case .fastForwardOnly:
            try setConfigurationValue(nil, for: "pull.rebase")
            try setConfigurationValue("only", for: "pull.ff")
        }
    }

    // MARK: Refspecs

    /// A remote's fetch or push refspecs, as configured.
    public func refspecs(ofRemote name: String, direction: RefspecDirection) throws -> [String] {
        try requireRemote(name)
        return try configurationValues("remote.\(name).\(direction.configurationVariable)")
    }

    /// Replaces a remote's fetch or push refspecs, refusing any that git
    /// could not read.
    public func setRefspecs(_ refspecs: [String], ofRemote name: String, direction: RefspecDirection) throws {
        try requireRemote(name)
        let refspecs = refspecs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let invalid = refspecs.first(where: { !Self.isValidRefspec($0, direction: direction) }) {
            throw ConfigurationError.invalidRefspec(invalid)
        }
        try setConfigurationValues(refspecs, for: "remote.\(name).\(direction.configurationVariable)")
    }

    /// Whether git can read `refspec`, such as
    /// `+refs/heads/*:refs/remotes/origin/*`.
    public static func isValidRefspec(_ refspec: String, direction: RefspecDirection) -> Bool {
        GitEnvironment.ensureInitialized()
        let trimmed = refspec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        var parsed: OpaquePointer?
        guard git_refspec_parse(&parsed, trimmed, direction == .fetch ? 1 : 0) == 0 else { return false }
        git_refspec_free(parsed)
        return true
    }

    // MARK: A remote's default branch

    /// The branch a remote has checked out, as the last clone or
    /// `git remote set-head` recorded it in `refs/remotes/<name>/HEAD`: its
    /// short name, such as `main`.
    public func defaultBranch(ofRemote name: String) throws -> String? {
        try requireRemote(name)
        var reference: OpaquePointer?
        let code = git_reference_lookup(&reference, pointer, "refs/remotes/\(name)/HEAD")
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try check(code)
        defer { git_reference_free(reference) }
        guard let target = git_reference_symbolic_target(reference).map({ String(cString: $0) }) else { return nil }
        let prefix = "refs/remotes/\(name)/"
        return target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : target
    }

    /// Records which of a remote's branches is its default, as
    /// `git remote set-head <name> <branch>`, or forgets it with `nil`. The
    /// remote branch must have been fetched.
    public func setDefaultBranch(_ branch: String?, ofRemote name: String) throws {
        try requireRemote(name)
        let head = "refs/remotes/\(name)/HEAD"
        guard let branch, !branch.isEmpty else {
            var reference: OpaquePointer?
            let code = git_reference_lookup(&reference, pointer, head)
            if code == GIT_ENOTFOUND.rawValue { return }
            try check(code)
            defer { git_reference_free(reference) }
            try check(git_reference_delete(reference))
            return
        }
        let target = "refs/remotes/\(name)/\(branch)"
        var existing = git_oid()
        guard git_reference_name_to_id(&existing, pointer, target) == 0 else {
            throw ConfigurationError.remoteBranchNotFetched(remote: name, branch: branch)
        }
        var reference: OpaquePointer?
        try check(git_reference_symbolic_create(&reference, pointer, head, target, 1, "remote set-head"))
        git_reference_free(reference)
    }

    // MARK: Helpers

    private func requireRemote(_ name: String) throws {
        var remote: OpaquePointer?
        let code = git_remote_lookup(&remote, pointer, name)
        if code == GIT_ENOTFOUND.rawValue || code == GIT_EINVALIDSPEC.rawValue { throw RemoteError.remoteNotFound(name) }
        try check(code)
        git_remote_free(remote)
    }

    /// Runs `body` with one level of the repository's configuration, which
    /// is written straight to that level's file.
    private func withConfiguration<T>(_ level: ConfigurationLevel, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var all: OpaquePointer?
        try check(git_repository_config(&all, pointer))
        defer { git_config_free(all) }
        var single: OpaquePointer?
        let code = git_config_open_level(&single, all, level.libgit2Level)
        // A level with no file, such as no global configuration yet, is empty.
        if code == GIT_ENOTFOUND.rawValue {
            if level == .local { throw ConfigurationError.noLocalConfiguration }
            return try body(nil)
        }
        try check(code)
        defer { git_config_free(single) }
        return try body(single)
    }
}

/// git's rules for configuration keys, which libgit2 keeps to itself.
enum ConfigurationKey {
    /// The key as git stores and lists it, section and variable lowercased
    /// and a subsection kept as written; `nil` when git would refuse it.
    static func normalized(_ key: String) -> String? {
        guard let firstDot = key.firstIndex(of: "."), let lastDot = key.lastIndex(of: ".") else { return nil }
        let section = key[..<firstDot]
        let variable = key[key.index(after: lastDot)...]
        guard !section.isEmpty, section.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let first = variable.first, first.isASCII, first.isLetter,
              variable.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        guard firstDot != lastDot else { return "\(section.lowercased()).\(variable.lowercased())" }
        let subsection = key[key.index(after: firstDot)..<lastDot]
        guard !subsection.contains("\n"), !subsection.contains("\0") else { return nil }
        return "\(section.lowercased()).\(subsection).\(variable.lowercased())"
    }
}

/// Which way a refspec maps references.
public enum RefspecDirection: Hashable, Sendable, CaseIterable {
    case fetch
    case push

    var configurationVariable: String {
        switch self {
        case .fetch: "fetch"
        case .push: "push"
        }
    }
}

public enum ConfigurationError: Error, Hashable, Sendable, LocalizedError {
    case invalidKey(String)
    case invalidRefspec(String)
    case invalidBranchName(String)
    case remoteBranchNotFetched(remote: String, branch: String)
    case noLocalConfiguration

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let key):
            "“\(key)” is not a configuration key git can store. Keys look like section.name or section.subsection.name."
        case .invalidRefspec(let refspec):
            "“\(refspec)” is not a refspec git can read. Refspecs look like +refs/heads/*:refs/remotes/origin/*."
        case .invalidBranchName(let name):
            "“\(name)” is not a valid branch name."
        case .remoteBranchNotFetched(let remote, let branch):
            "There is no remote branch “\(remote)/\(branch)”. Fetch “\(remote)” first."
        case .noLocalConfiguration:
            "This repository has no configuration file."
        }
    }
}

extension ConfigurationLevel {
    fileprivate var libgit2Level: git_config_level_t {
        switch self {
        case .local: GIT_CONFIG_LEVEL_LOCAL
        case .global: GIT_CONFIG_LEVEL_GLOBAL
        }
    }
}

// MARK: Creating repositories

/// What a new, empty repository starts with.
public struct NewRepositoryOptions: Hashable, Sendable {
    /// The branch `HEAD` starts on, such as `main`.
    public var initialBranch: String
    /// Files to write in the working copy, by path: a README, a .gitignore.
    public var files: [String: String]
    /// Commit the files as the first commit, when there are any and an
    /// author is configured.
    public var commitFiles: Bool

    public init(initialBranch: String, files: [String: String] = [:], commitFiles: Bool = true) {
        self.initialBranch = initialBranch
        self.files = files
        self.commitFiles = commitFiles
    }
}

extension Repository {
    /// Creates an empty repository with a working copy at `url`, on
    /// `options.initialBranch`, writes the starting files and commits them
    /// when it can. The folder must not hold a repository already.
    @concurrent
    public static func create(at url: URL, options: NewRepositoryOptions) async throws -> Repository {
        GitEnvironment.ensureInitialized()
        guard isValidBranchName(options.initialBranch) else {
            throw ConfigurationError.invalidBranchName(options.initialBranch)
        }
        guard !exists(at: url) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var initOptions = git_repository_init_options()
        try check(git_repository_init_options_init(&initOptions, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)))
        initOptions.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue
        var pointer: OpaquePointer?
        try options.initialBranch.withCString { branch in
            initOptions.initial_head = branch
            try check(git_repository_init_ext(&pointer, url.path, &initOptions))
        }
        git_repository_free(pointer)

        for (path, text) in options.files.sorted(by: { $0.key < $1.key }) {
            try Data(text.utf8).write(to: url.appending(path: path), options: .atomic)
        }
        let repository = try Repository(at: url)
        if options.commitFiles, !options.files.isEmpty, await repository.identity() != nil {
            try await repository.stage(options.files.keys.sorted())
            try await repository.commit(message: "Initial commit")
        }
        return repository
    }

    /// Whether `name` can be a branch's short name.
    public static func isValidBranchName(_ name: String) -> Bool {
        GitEnvironment.ensureInitialized()
        guard !name.isEmpty else { return false }
        var valid: Int32 = 0
        return git_branch_name_is_valid(&valid, name) == 0 && valid != 0
    }
}
