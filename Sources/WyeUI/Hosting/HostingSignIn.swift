import Foundation

/// Checks a token against the service and keeps the account it belongs to.
enum HostingSignIn {
    /// Reads `https://git.example.com` or `git.example.com:8443` as a
    /// scheme and a host.
    static func parseHost(_ text: String) -> (scheme: String, host: String)? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var scheme = "https"
        if let range = text.range(of: "://") {
            scheme = String(text[..<range.lowerBound])
            text = String(text[range.upperBound...])
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard ["http", "https"].contains(scheme), !text.isEmpty, !text.contains("/"), !text.contains(" "),
              URL(string: "\(scheme)://\(text)")?.host != nil else { return nil }
        return (scheme, text)
    }

    /// Asks the service who the token belongs to and saves that account,
    /// updating the one already kept for the same login on the host.
    @discardableResult
    static func signIn(
        kind: HostingKind, host: String, scheme: String = "https", secret: HostingSecret, email: String? = nil,
        method: HostingAccount.SignIn, store: AccountStore, transport: any HTTPTransport
    ) async throws -> HostingAccount {
        let host = kind == .bitbucket ? kind.defaultHost : host.lowercased()
        let email = email?.trimmingCharacters(in: .whitespaces).trimmedToNil
        var draft = HostingAccount(kind: kind, host: host, scheme: scheme, login: "", email: email, signIn: method)
        let service = HostingServices.service(
            kind: kind, host: host, scheme: scheme, user: nil,
            tokens: FixedToken(value: draft.authorization(token: secret.token)), transport: transport
        )
        let user = try await service.currentUser()
        // The same login, or a token kept from a remote's prompt for it,
        // becomes this account rather than a second one.
        let existing = store.accounts(forHost: host).first {
            ($0.kind == kind || $0.signIn == .gitPrompt) && $0.login.lowercased() == user.login.lowercased()
        }
        draft.id = existing?.id ?? draft.id
        draft.login = user.login
        draft.name = user.name
        draft.avatarURL = user.avatarURL
        draft.gitUsername = user.login
        draft.serviceID = user.serviceID
        try store.save(draft, secret: secret)
        return draft
    }
}

private extension String {
    var trimmedToNil: String? { isEmpty ? nil : self }
}
