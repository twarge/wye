import Foundation
import GitKit
import Security
import Synchronization

/// A host Twig keeps an access token for.
struct SavedAccount: Identifiable, Hashable {
    var host: String
    var username: String

    var id: String { host }
}

/// Access tokens, one per host: saved ones in the Keychain, and ones the
/// user chose not to save in memory until the app quits.
///
/// GitKit asks for credentials on a repository's own thread, so this is
/// `Sendable` and reads the Keychain directly rather than through the main
/// actor.
final class CredentialStore: CredentialProvider {
    static let shared = CredentialStore()

    /// Keychain items are generic passwords under this service, with the
    /// host as the account. That keeps Twig's items apart from every other
    /// password the user has for the same host.
    private let service = "Twig access token"
    private let unsaved = Mutex<[String: Credential]>([:])

    func credential(for request: CredentialRequest) -> Credential? {
        if let credential = unsaved.withLock({ $0[request.host] }) {
            return credential
        }
        return try? savedCredential(for: request.host)
    }

    /// Keeps a credential for this run of the app, or in the Keychain.
    func store(_ credential: Credential, for host: String, inKeychain: Bool) throws {
        if inKeychain {
            try save(credential, for: host)
            unsaved.withLock { $0[host] = nil }
        } else {
            unsaved.withLock { $0[host] = credential }
        }
    }

    /// Forgets a host's credential, saved or not.
    func remove(host: String) throws {
        unsaved.withLock { $0[host] = nil }
        let status = SecItemDelete(baseQuery(host: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// The hosts with a saved token, by host name.
    func savedAccounts() throws -> [SavedAccount] {
        var query = baseQuery(host: nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError(status: status)
        }
        return items.compactMap { item in
            guard let host = item[kSecAttrAccount as String] as? String else { return nil }
            let username = (item[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
            return SavedAccount(host: host, username: username ?? "")
        }
        .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }

    // MARK: Keychain

    private func savedCredential(for host: String) throws -> Credential? {
        var query = baseQuery(host: host)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        let username = (item[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return Credential(username: username ?? "", token: token)
    }

    private func save(_ credential: Credential, for host: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(credential.token.utf8),
            // The username is not secret, but the account attribute already
            // holds the host, so it rides along as the item's generic data.
            kSecAttrGeneric as String: Data(credential.username.utf8),
            kSecAttrLabel as String: "Twig: \(host)"
        ]
        var status = SecItemUpdate(baseQuery(host: host) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(host: host).merging(attributes) { $1 }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery(host: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let host {
            query[kSecAttrAccount as String] = host
        }
        return query
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
        return "The Keychain could not be used: \(message)"
    }
}
