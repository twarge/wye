import Clibgit2
import Foundation
import Synchronization

/// Process-wide libgit2 setup.
public enum GitEnvironment {
    private static let globalConfigurationDirectory = Mutex<URL?>(nil)

    private static let initialized: Bool = {
        git_libgit2_init()
        // A repository is opened because the user picked it. Being owned by
        // another user (an external volume, a file provider) is no reason to
        // refuse it.
        _ = clibgit2_set_owner_validation(0)
        return true
    }()

    static func ensureInitialized() {
        _ = initialized
    }

    /// The version of the linked libgit2, such as `1.9.7`.
    public static var libgit2Version: String {
        ensureInitialized()
        var major: Int32 = 0, minor: Int32 = 0, revision: Int32 = 0
        git_libgit2_version(&major, &minor, &revision)
        return "\(major).\(minor).\(revision)"
    }

    /// Points libgit2 at the directory holding the app's own global
    /// `.gitconfig`. A sandboxed app cannot read the one in the user's home.
    public static func useGlobalConfiguration(in directory: URL) throws {
        ensureInitialized()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try check(clibgit2_set_search_path(GIT_CONFIG_LEVEL_GLOBAL.rawValue, directory.path))
        globalConfigurationDirectory.withLock { $0 = directory }
    }

    /// The author identity from the global configuration, if one is set.
    public static func globalIdentity() -> GitIdentity? {
        ensureInitialized()
        var configuration: OpaquePointer?
        guard git_config_open_default(&configuration) == 0 else { return nil }
        defer { git_config_free(configuration) }
        guard let name = string(for: "user.name", in: configuration),
              let email = string(for: "user.email", in: configuration) else { return nil }
        return GitIdentity(name: name, email: email)
    }

    /// Writes the author identity to the global configuration.
    public static func setGlobalIdentity(_ identity: GitIdentity) throws {
        ensureInitialized()
        let directory = globalConfigurationDirectory.withLock { $0 }
            ?? URL.homeDirectory
        var configuration: OpaquePointer?
        try check(git_config_open_ondisk(&configuration, directory.appending(path: ".gitconfig").path))
        defer { git_config_free(configuration) }
        try check(git_config_set_string(configuration, "user.name", identity.name))
        try check(git_config_set_string(configuration, "user.email", identity.email))
    }

    static func string(for key: String, in configuration: OpaquePointer?) -> String? {
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        guard git_config_get_string_buf(&buffer, configuration, key) == 0, let pointer = buffer.ptr else {
            return nil
        }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }
}

/// The name and email recorded as the author of new commits.
public struct GitIdentity: Hashable, Sendable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}
