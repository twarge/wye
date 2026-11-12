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
    /// Whether iCloud Keychain carries it to the user's other devices.
    var isSynced = false
}

/// Whether SSH keys are kept in iCloud Keychain. Off unless the user turns
/// it on: a private key then leaves this device, end-to-end encrypted, for
/// the user's others.
enum SSHKeyPreferences {
    static let syncsKey = "ssh.syncKeys"

    static var syncsKeys: Bool {
        UserDefaults.standard.bool(forKey: syncsKey)
    }
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
    let knownHosts = KnownHosts(file: .applicationSupportDirectory.appending(path: "Wye/known_hosts"))

    /// Items are generic passwords under this service, with a random
    /// identifier as the account. The key's description rides along as the
    /// item's generic attribute, so that listing keys reads no secret.
    private let service = "Wye SSH key"

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
                fingerprint: publicKey.fingerprint, created: description.created,
                isSynced: Self.isSynchronizable(item)
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
        try add(key, id: UUID().uuidString, created: .now, synced: SSHKeyPreferences.syncsKeys)
    }

    /// Moves every key into iCloud Keychain, or back to this device alone.
    /// A key is taken out and put back, the same key under the same
    /// identifier, so that what refers to it (a signing key, say) still
    /// does. Stops at the first that cannot be moved, with the rest as
    /// they were.
    func setSynced(_ synced: Bool) throws {
        for stored in try keys() where stored.isSynced != synced {
            guard let key = try privateKey(id: stored.id) else { continue }
            try remove(stored)
            do {
                try add(key, id: stored.id, created: stored.created, synced: synced)
            } catch {
                // Never lose a key to a failed move: back where it was.
                _ = try? add(key, id: stored.id, created: stored.created, synced: stored.isSynced)
                throw error
            }
        }
    }

    @discardableResult
    private func add(_ key: SSHPrivateKey, id: String, created: Date, synced: Bool) throws -> StoredSSHKey {
        let description = Description(
            kind: key.kind, comment: key.comment, publicKey: key.publicKey.openSSH, created: created
        )
        var item = baseQuery(id: id)
        item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrGeneric as String] = try JSONEncoder().encode(description)
        item[kSecAttrLabel as String] = key.comment.isEmpty ? "Wye SSH key" : "Wye SSH key: \(key.comment)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrSynchronizable as String] = synced
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return try keys().first { $0.id == id } ?? StoredSSHKey(
            id: id, kind: key.kind, comment: key.comment, publicKeyLine: key.openSSHPublicKey,
            fingerprint: key.publicKey.fingerprint, created: description.created, isSynced: synced
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

    private static func isSynchronizable(_ item: [String: Any]) -> Bool {
        if let flag = item[kSecAttrSynchronizable as String] as? Bool { return flag }
        return (item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
    }

    private func baseQuery(id: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Keys on this device alone and keys in iCloud Keychain alike.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let id {
            query[kSecAttrAccount as String] = id
        }
        return query
    }
}
