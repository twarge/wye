import Foundation
import GitKit
import Synchronization

/// The credentials git operations use: HTTPS tokens from the accounts (the
/// repository's chosen account, or its host's default), ones the user chose
/// not to save in memory until the app quits, and SSH keys.
///
/// GitKit asks for credentials on a repository's own thread, so this is
/// `Sendable` and reads the accounts directly rather than through the main
/// actor.
final class CredentialStore: CredentialProvider {
    static let shared = CredentialStore(accounts: .shared)

    private let accounts: AccountStore
    private let unsaved = Mutex<[String: Credential]>([:])

    init(accounts: AccountStore) {
        self.accounts = accounts
    }

    func credential(for request: CredentialRequest) -> Credential? {
        let host = request.host.lowercased()
        if let credential = unsaved.withLock({ $0[host] }) {
            return credential
        }
        return accounts.credential(forURL: request.url, host: host)
    }

    /// Every SSH key, in turn: the server takes the first it knows.
    func sshKeys(for request: SSHKeyRequest) -> [SSHPrivateKey] {
        SSHKeyStore.shared.privateKeys()
    }

    func trust(for hostKey: SSHHostKey) -> SSHHostKeyTrust {
        SSHKeyStore.shared.knownHosts.trust(for: hostKey)
    }

    /// Keeps a credential a prompt was answered with: for this run of the
    /// app, or in the host's account in the Keychain.
    func store(_ credential: Credential, for host: String, inKeychain: Bool) throws {
        let host = host.lowercased()
        if inKeychain {
            try accounts.storeGitCredential(credential, forHost: host)
            unsaved.withLock { $0[host] = nil }
        } else {
            unsaved.withLock { $0[host] = credential }
        }
    }

    /// Forgets a token kept for this run of the app.
    func forgetUnsaved(host: String) {
        unsaved.withLock { $0[host.lowercased()] = nil }
    }
}
