import Foundation
import GitKit

/// Why a commit could not be signed as the settings ask.
enum SigningSetupError: Error, LocalizedError {
    case noKey
    case keyMissing

    var errorDescription: String? {
        switch self {
        case .noKey:
            "Commit signing is on, but there is no SSH key to sign with. Create or import one in Settings, or turn signing off."
        case .keyMissing:
            "The SSH key chosen for signing commits is no longer in the Keychain. Choose another in Settings."
        }
    }
}

/// The private keys commits are signed with, read from the Keychain once
/// and kept for the session, since a repository's signer is set again on
/// every refresh.
@MainActor
enum SigningKeys {
    private static var cache: [String: SSHPrivateKey] = [:]

    /// The signer a plan calls for, or `nil` when it does not sign.
    static func signer(for plan: SigningPlan) throws -> CommitSigner? {
        guard plan.signs else { return nil }
        // Listing reads no secret, and catches a key deleted since it was kept.
        let keys = try SSHKeyStore.shared.keys()
        guard let id = plan.keyID ?? keys.first?.id else { throw SigningSetupError.noKey }
        guard keys.contains(where: { $0.id == id }) else { throw SigningSetupError.keyMissing }
        if let key = cache[id] { return CommitSigner(key: key) }
        guard let key = try SSHKeyStore.shared.signingKey(id: id) else { throw SigningSetupError.keyMissing }
        cache[id] = key
        return CommitSigner(key: key)
    }
}
