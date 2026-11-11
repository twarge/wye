import Foundation
import GitKit
import Security

/// An SSH key Wye keeps, as the interface lists it. The private half is
/// read from the Keychain only when a connection needs it.
struct StoredSSHKey: Identifiable, Hashable {
    let id: String
    var kind: SSHKeyKind
    var comment: String
    /// `ssh-ed25519 AAAA… comment`, to paste into a hosting service.
    var publicKeyLine: String
    var fingerprint: String
    var created: Date
}

/// SSH private keys, each a generic password item in the Keychain, and the
/// file of trusted host keys.
///
/// GitKit asks for keys on a repository's own thread, so this is `Sendable`
/// and reads the Keychain directly, as ``CredentialStore`` does.
final class SSHKeyStore: Sendable {
    static let shared = SSHKeyStore()

    /// The hosts whose keys the user has trusted, in Wye's own known_hosts,
    /// never the one in `~/.ssh`.
    let knownHosts = KnownHosts(file: .applicationSupportDirectory.appending(path: "Twig/known_hosts"))

    /// Items are generic passwords under this service, with a random
    /// identifier as the account. The key's description rides along as the
    /// item's generic attribute, so that listing keys reads no secret.
    /// The app's first name, kept so keys saved under it are still found.
    private let service = "Twig SSH key"

    private struct Description: Codable {
        var kind: SSHKeyKind
        var comment: String
        var publicKey: String
        var created: Date
    }

    /// Every key, oldest first: the order they are offered to servers in.
    func keys() throws -> [StoredSSHKey] {
        var query = baseQuery(id: nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError(status: status)
        }
        return items.compactMap { item -> StoredSSHKey? in
            guard let id = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecAttrGeneric as String] as? Data,
                  let description = try? JSONDecoder().decode(Description.self, from: data),
                  let publicKey = try? SSHPublicKey(openSSH: description.publicKey) else { return nil }
            return StoredSSHKey(
                id: id, kind: description.kind, comment: description.comment,
                publicKeyLine: description.comment.isEmpty
                    ? publicKey.openSSH : publicKey.openSSH + " " + description.comment,
                fingerprint: publicKey.fingerprint, created: description.created
            )
        }
        .sorted { $0.created < $1.created }
    }

    /// The private keys, oldest first, for a connection. Keys that cannot
    /// be read are left out rather than failing the connection.
    func privateKeys() -> [SSHPrivateKey] {
        ((try? keys()) ?? []).compactMap { try? privateKey(id: $0.id) }
    }

    /// One key's private half, to sign commits with; `nil` when it is gone.
    func signingKey(id: String) throws -> SSHPrivateKey? {
        try privateKey(id: id)
    }

    @discardableResult
    func add(_ key: SSHPrivateKey) throws -> StoredSSHKey {
        let id = UUID().uuidString
        let description = Description(
            kind: key.kind, comment: key.comment, publicKey: key.publicKey.openSSH, created: .now
        )
        var item = baseQuery(id: id)
        item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrGeneric as String] = try JSONEncoder().encode(description)
        item[kSecAttrLabel as String] = key.comment.isEmpty ? "Wye SSH key" : "Wye SSH key: \(key.comment)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return try keys().first { $0.id == id } ?? StoredSSHKey(
            id: id, kind: key.kind, comment: key.comment, publicKeyLine: key.openSSHPublicKey,
            fingerprint: key.publicKey.fingerprint, created: description.created
        )
    }

    func remove(_ key: StoredSSHKey) throws {
        let status = SecItemDelete(baseQuery(id: key.id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func privateKey(id: String) throws -> SSHPrivateKey? {
        var query = baseQuery(id: id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [String: Any],
              let secret = item[kSecValueData as String] as? Data,
              let data = item[kSecAttrGeneric as String] as? Data,
              let description = try? JSONDecoder().decode(Description.self, from: data) else {
            throw KeychainError(status: status)
        }
        return try SSHPrivateKey(kind: description.kind, rawRepresentation: secret, comment: description.comment)
    }

    private func baseQuery(id: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let id {
            query[kSecAttrAccount as String] = id
        }
        return query
    }
}
