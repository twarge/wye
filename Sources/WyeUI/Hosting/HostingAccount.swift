import Foundation
import GitKit
import Security
import Synchronization

/// An account on a hosting service, or on a git host Wye only knows a
/// token for. The token itself is kept apart, in the Keychain.
struct HostingAccount: Codable, Identifiable, Hashable, Sendable {
    enum SignIn: String, Codable, Hashable, Sendable {
        /// A personal access token, checked against the service.
        case token
        /// The OAuth device flow.
        case oauth
        /// A username and token given when a remote asked, never checked
        /// against the service's API.
        case gitPrompt
    }

    var id: UUID
    /// `nil` for a git host whose service Wye does not know.
    var kind: HostingKind?
    /// The host, with a port when it has one: `github.com`,
    /// `git.example.com:8443`.
    var host: String
    /// `https`, or `http` for a self-hosted service without TLS.
    var scheme: String
    var login: String
    var name: String?
    var avatarURL: URL?
    /// The Atlassian account email Bitbucket's API signs in with.
    var email: String?
    /// The username git sends with the token over HTTPS.
    var gitUsername: String
    var signIn: SignIn
    /// Bitbucket's account id, for its queries.
    var serviceID: String?

    init(
        id: UUID = UUID(), kind: HostingKind?, host: String, scheme: String = "https", login: String,
        name: String? = nil, avatarURL: URL? = nil, email: String? = nil, gitUsername: String? = nil,
        signIn: SignIn, serviceID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.host = host.lowercased()
        self.scheme = scheme
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.email = email
        self.gitUsername = gitUsername ?? login
        self.signIn = signIn
        self.serviceID = serviceID
    }

    /// Whether the service's API can be used with it: a known service
    /// and a sign-in that was checked.
    var usesService: Bool {
        kind != nil && signIn != .gitPrompt
    }

    var user: HostingUser {
        HostingUser(login: login, name: name, avatarURL: avatarURL, serviceID: serviceID)
    }

    /// `octocat on github.com`.
    var title: String {
        "\(login) on \(host)"
    }

    /// How API requests carry the token.
    func authorization(token: String) -> HostingAuthorization {
        switch kind {
        case .gitea: .token(token)
        case .bitbucket: email.map { .basic(username: $0, password: token) } ?? .bearer(token)
        case .github, .gitlab, nil: .bearer(token)
        }
    }

    /// The username git sends with the token. GitLab wants `oauth2` with
    /// an OAuth token; Bitbucket the account's username, not the email.
    var gitCredentialUsername: String {
        if kind == .gitlab, signIn == .oauth { return "oauth2" }
        return gitUsername.isEmpty ? login : gitUsername
    }
}

/// A token and, for one that expires, how to get the next.
struct HostingSecret: Codable, Hashable, Sendable {
    var token: String
    var refreshToken: String?
    var expiresAt: Date?

    /// Whether it has expired, or will within a minute.
    func isExpiring(now: Date = .now) -> Bool {
        expiresAt.map { $0 < now.addingTimeInterval(60) } ?? false
    }
}

extension HostingKind {
    /// The kind the web links know it by.
    var linkKind: HostedRepository.Kind {
        switch self {
        case .github: .github
        case .gitlab: .gitlab
        case .bitbucket: .bitbucket
        case .gitea: .gitea
        }
    }
}

// MARK: Secrets

/// A generic password: its account attribute, its generic attribute, and
/// the secret.
struct SecretItem: Hashable, Sendable {
    var account: String
    var generic: Data?
    var data: Data
}

/// Where secrets are kept: the Keychain in the app, memory in tests, which
/// must never read or write the user's Keychain.
protocol SecretStore: Sendable {
    func items(service: String) throws -> [SecretItem]
    func set(_ item: SecretItem, label: String, service: String) throws
    func delete(account: String, service: String) throws
}

struct KeychainSecretStore: SecretStore {
    func items(service: String) throws -> [SecretItem] {
        // Attributes first, then each item's data: the file-based Keychain
        // on macOS will not return data for many items at once.
        var query = baseQuery(service: service, account: nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let found = result as? [[String: Any]] else { throw KeychainError(status: status) }
        return try found.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  let data = try data(service: service, account: account) else { return nil }
            return SecretItem(account: account, generic: attributes[kSecAttrGeneric as String] as? Data, data: data)
        }
    }

    func set(_ item: SecretItem, label: String, service: String) throws {
        var attributes: [String: Any] = [
            kSecValueData as String: item.data,
            kSecAttrLabel as String: label
        ]
        attributes[kSecAttrGeneric as String] = item.generic ?? Data()
        let query = baseQuery(service: service, account: item.account)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query.merging(attributes) { $1 }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(account: String, service: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func data(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    private func baseQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}

/// Secrets in memory, for tests.
final class MemorySecretStore: SecretStore {
    private let storage = Mutex<[String: [String: SecretItem]]>([:])

    func items(service: String) throws -> [SecretItem] {
        storage.withLock { Array(($0[service] ?? [:]).values).sorted { $0.account < $1.account } }
    }

    func set(_ item: SecretItem, label: String, service: String) throws {
        storage.withLock { $0[service, default: [:]][item.account] = item }
    }

    func delete(account: String, service: String) throws {
        _ = storage.withLock { $0[service]?.removeValue(forKey: account) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
        return "The Keychain could not be used: \(message)"
    }
}

/// Small choices kept between launches: each host's default account and
/// each repository's own choice. `UserDefaults` in the app, a private
/// suite in tests.
protocol AccountPreferences: Sendable {
    func dictionary(forKey key: String) -> [String: String]
    func set(_ value: [String: String], forKey key: String)
}

struct DefaultsAccountPreferences: AccountPreferences {
    /// A suite name, or `nil` for the standard defaults.
    var suite: String?

    private var defaults: UserDefaults {
        suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func dictionary(forKey key: String) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func set(_ value: [String: String], forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

final class MemoryAccountPreferences: AccountPreferences {
    private let storage = Mutex<[String: [String: String]]>([:])

    func dictionary(forKey key: String) -> [String: String] {
        storage.withLock { $0[key] ?? [:] }
    }

    func set(_ value: [String: String], forKey key: String) {
        storage.withLock { $0[key] = value }
    }
}
