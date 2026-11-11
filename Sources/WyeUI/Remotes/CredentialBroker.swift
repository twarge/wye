import Foundation
import GitKit
import Observation

/// A request, shown as a sheet, for a host's username and access token.
struct CredentialPrompt: Identifiable {
    let id = UUID()
    let host: String
    var username: String
    /// Whether the remote refused the credentials Wye had for it.
    let wasRejected: Bool
}

/// Runs network operations, asking the user for credentials when a remote
/// wants ones Wye does not have, and running the operation again with them.
///
/// GitKit cannot wait for a prompt in the middle of an operation, so it fails
/// instead, saying which host wanted credentials; this turns that failure
/// into a prompt and a retry.
@MainActor
@Observable
final class CredentialBroker {
    /// The prompt to show, while one is waiting for an answer.
    var prompt: CredentialPrompt?
    /// An SSH server's key to trust or refuse.
    var hostKeyPrompt: HostKeyPrompt?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Runs `operation` until it succeeds, fails for another reason, or the
    /// user declines to give credentials, which throws `CancellationError`.
    func run<Result>(_ operation: () async throws -> Result) async throws -> Result {
        while true {
            do {
                return try await operation()
            } catch let error as RemoteError {
                if let hostKeyPrompt = HostKeyPrompt(error) {
                    guard await ask({ self.hostKeyPrompt = hostKeyPrompt }) else { throw CancellationError() }
                    try SSHKeyStore.shared.knownHosts.trust(hostKeyPrompt.hostKey)
                    continue
                }
                if let sshKeyPrompt = SSHKeyPrompt(error) {
                    // Nothing to answer on the spot: the key has to be made
                    // or added to the account first. The settings open at
                    // the keys, saying why, and the operation stops.
                    SettingsFocus.shared.showSSHKeys(for: sshKeyPrompt)
                    throw CancellationError()
                }
                guard let (host, username) = error.credentialHost else { throw error }
                let wasRejected = if case .credentialsRejected = error { true } else { false }
                let saved = CredentialStore.shared.credential(
                    for: CredentialRequest(url: host, host: host, username: username)
                )
                let prompt = CredentialPrompt(
                    host: host, username: saved?.username ?? username ?? "", wasRejected: wasRejected
                )
                guard await ask({ self.prompt = prompt }) else { throw CancellationError() }
            }
        }
    }

    /// Keeps the answer to the current prompt and lets the operation retry.
    func answer(_ credential: Credential, saveInKeychain: Bool) throws {
        guard let prompt else { return }
        try CredentialStore.shared.store(credential, for: prompt.host, inKeychain: saveInKeychain)
        finish(answered: true)
    }

    /// Answers an SSH prompt: trust the host's key, or try the keys again.
    func proceed() {
        finish(answered: true)
    }

    /// Declines the current prompt; the operation stops.
    func decline() {
        finish(answered: false)
    }

    /// A prompt's sheet went away. Unless it was answered, that declines
    /// it; a newer prompt, shown before the old sheet finished leaving,
    /// stays.
    func dismissed(_ id: UUID) {
        if prompt?.id == id || hostKeyPrompt?.id == id {
            decline()
        }
    }

    private func ask(_ show: () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            show()
        }
    }

    private func finish(answered: Bool) {
        prompt = nil
        hostKeyPrompt = nil
        continuation?.resume(returning: answered)
        continuation = nil
    }
}
