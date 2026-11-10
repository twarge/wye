import Foundation
import GitKit
import Observation

/// A request, shown as a sheet, for a host's username and access token.
struct CredentialPrompt: Identifiable {
    let id = UUID()
    let host: String
    var username: String
    /// Whether the remote refused the credentials Twig had for it.
    let wasRejected: Bool
}

/// Runs network operations, asking the user for credentials when a remote
/// wants ones Twig does not have, and running the operation again with them.
///
/// GitKit cannot wait for a prompt in the middle of an operation, so it fails
/// instead, saying which host wanted credentials; this turns that failure
/// into a prompt and a retry.
@MainActor
@Observable
final class CredentialBroker {
    /// The prompt to show, while one is waiting for an answer.
    var prompt: CredentialPrompt?

    private var continuation: CheckedContinuation<Bool, Never>?

    /// Runs `operation` until it succeeds, fails for another reason, or the
    /// user declines to give credentials, which throws `CancellationError`.
    func run<Result>(_ operation: () async throws -> Result) async throws -> Result {
        while true {
            do {
                return try await operation()
            } catch let error as RemoteError {
                guard let (host, username) = error.credentialHost else { throw error }
                let wasRejected = if case .credentialsRejected = error { true } else { false }
                let saved = CredentialStore.shared.credential(
                    for: CredentialRequest(url: host, host: host, username: username)
                )
                let prompt = CredentialPrompt(
                    host: host, username: saved?.username ?? username ?? "", wasRejected: wasRejected
                )
                guard await ask(prompt) else { throw CancellationError() }
            }
        }
    }

    /// Keeps the answer to the current prompt and lets the operation retry.
    func answer(_ credential: Credential, saveInKeychain: Bool) throws {
        guard let prompt else { return }
        try CredentialStore.shared.store(credential, for: prompt.host, inKeychain: saveInKeychain)
        finish(answered: true)
    }

    /// Declines the current prompt; the operation stops.
    func decline() {
        finish(answered: false)
    }

    private func ask(_ prompt: CredentialPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.prompt = prompt
        }
    }

    private func finish(answered: Bool) {
        prompt = nil
        continuation?.resume(returning: answered)
        continuation = nil
    }
}
