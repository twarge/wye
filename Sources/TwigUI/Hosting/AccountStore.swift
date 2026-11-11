import Foundation
import GitKit
import Observation
import Synchronization

/// Every account, several per host if need be, with their tokens in the
/// Keychain; which account each host uses unless told otherwise; and which
/// account a repository uses when it is not its host's default.
///
/// Git asks for credentials on a repository's own thread, so this is
/// `Sendable` and keeps a copy of the accounts (not the tokens) in memory.
final class AccountStore: Sendable {
    static let shared = AccountStore(secrets: KeychainSecretStore(), preferences: DefaultsAccountPreferences())

    /// Keychain items are generic passwords under this service, with the
    /// account's id as the item's account, the account as JSON in its
    /// generic attribute, and the token as JSON in its data.
    static let service = "Twig hosting account"
    /// Where earlier versions kept one token per host: the host as the
    /// item's account, the username as its generic attribute, the token
    /// as its data.
    static let legacyService = "Twig access token"

    static let defaultsKey = "hosting.defaultAccountByHost"
    static let repositoryKey = "hosting.accountByRepository"

    private let secrets: any SecretStore
    private let preferences: any AccountPreferences
    private let cache = Mutex<[HostingAccount]?>(nil)
    /// Tells the interface the accounts changed.
    let changes = AccountChanges()

    init(secrets: any SecretStore, preferences: any AccountPreferences) {
        self.secrets = secrets
        self.preferences = preferences
    }

    // MARK: Accounts

    /// Every account, by host and then login.
    func accounts() throws -> [HostingAccount] {
        if let cached = cache.withLock({ $0 }) { return cached }
        try migrateLegacyTokens()
        let accounts = try secrets.items(service: Self.service).compactMap { item -> HostingAccount? in
            guard let generic = item.generic else { return nil }
            return try? JSONDecoder().decode(HostingAccount.self, from: generic)
        }
        .sorted { ($0.host, $0.login.lowercased()) < ($1.host, $1.login.lowercased()) }
        cache.withLock { $0 = accounts }
        publishHostKinds(accounts)
        return accounts
    }

    func account(id: UUID) -> HostingAccount? {
        (try? accounts())?.first { $0.id == id }
    }

    func accounts(forHost host: String) -> [HostingAccount] {
        ((try? accounts()) ?? []).filter { $0.host == host.lowercased() }
    }

    /// Saves an account, and its token unless `secret` is `nil`, which keeps
    /// the one saved. The first account for a host becomes its default.
    func save(_ account: HostingAccount, secret: HostingSecret?) throws {
        let secret = try secret ?? self.secret(for: account.id)
        guard let secret else { throw HostingError.noAccount(host: account.host) }
        let item = SecretItem(
            account: account.id.uuidString,
            generic: try JSONEncoder().encode(account),
            data: try JSONEncoder().encode(secret)
        )
        try secrets.set(item, label: "Twig: \(account.title)", service: Self.service)
        invalidate()
        if defaultAccountID(forHost: account.host) == nil {
            setDefault(account.id, forHost: account.host)
        }
    }

    /// Forgets an account and its token, and every choice of it.
    func remove(_ id: UUID) throws {
        try secrets.delete(account: id.uuidString, service: Self.service)
        var defaults = preferences.dictionary(forKey: Self.defaultsKey)
        defaults = defaults.filter { $0.value != id.uuidString }
        preferences.set(defaults, forKey: Self.defaultsKey)
        var repositories = preferences.dictionary(forKey: Self.repositoryKey)
        repositories = repositories.filter { $0.value != id.uuidString }
        preferences.set(repositories, forKey: Self.repositoryKey)
        invalidate()
    }

    func secret(for id: UUID) throws -> HostingSecret? {
        guard let item = try secrets.items(service: Self.service).first(where: { $0.account == id.uuidString }) else {
            return nil
        }
        return try JSONDecoder().decode(HostingSecret.self, from: item.data)
    }

    // MARK: Defaults

    private func defaultAccountID(forHost host: String) -> UUID? {
        preferences.dictionary(forKey: Self.defaultsKey)[host.lowercased()].flatMap(UUID.init(uuidString:))
    }

    /// The account a host uses unless a repository chose another: the one
    /// set as default, or else the first that can use the service.
    func defaultAccount(forHost host: String) -> HostingAccount? {
        let candidates = accounts(forHost: host)
        if let id = defaultAccountID(forHost: host), let account = candidates.first(where: { $0.id == id }) {
            return account
        }
        return candidates.first(where: \.usesService) ?? candidates.first
    }

    func setDefault(_ id: UUID, forHost host: String) {
        var defaults = preferences.dictionary(forKey: Self.defaultsKey)
        defaults[host.lowercased()] = id.uuidString
        preferences.set(defaults, forKey: Self.defaultsKey)
        changes.changed()
    }

    // MARK: Per repository

    /// The account a repository's remote uses: its own choice, or its
    /// host's default.
    func account(forRemoteURL url: String) -> HostingAccount? {
        guard let hosted = HostedRepository(remoteURL: url) else { return nil }
        if let id = chosenAccountID(for: hosted), let account = account(id: id) { return account }
        return defaultAccount(forHost: hosted.host)
    }

    /// The account a repository chose over its host's default, if any.
    func chosenAccountID(for hosted: HostedRepository) -> UUID? {
        preferences.dictionary(forKey: Self.repositoryKey)[hosted.key].flatMap(UUID.init(uuidString:))
    }

    /// Makes a repository, by any of its remote URLs, use an account; `nil`
    /// goes back to the host's default.
    func setAccount(_ id: UUID?, forRemoteURL url: String) {
        guard let hosted = HostedRepository(remoteURL: url) else { return }
        var repositories = preferences.dictionary(forKey: Self.repositoryKey)
        repositories[hosted.key] = id?.uuidString
        preferences.set(repositories, forKey: Self.repositoryKey)
        changes.changed()
    }

    // MARK: Git credentials

    /// The username and token git sends to a host for a URL.
    func credential(forURL url: String, host: String) -> Credential? {
        let account = HostedRepository(remoteURL: url).flatMap { hosted -> HostingAccount? in
            chosenAccountID(for: hosted).flatMap { account(id: $0) }
        } ?? defaultAccount(forHost: host)
        guard let account, var secret = try? secret(for: account.id) else { return nil }
        if secret.isExpiring(), secret.refreshToken != nil {
            // Git cannot wait for an asynchronous answer; this runs on the
            // repository's thread, never the main one, so it can block.
            let expiring = secret
            if let refreshed = Self.blocking({ try await OAuthRefresh.refresh(account, secret: expiring, store: self) }) {
                secret = refreshed
            }
        }
        return Credential(username: account.gitCredentialUsername, token: secret.token)
    }

    /// Keeps a username and token a remote's prompt was answered with: the
    /// account of that login on the host gets the new token, or there is a
    /// new account, which becomes the host's default.
    @discardableResult
    func storeGitCredential(_ credential: Credential, forHost host: String) throws -> HostingAccount {
        let host = host.lowercased()
        let secret = HostingSecret(token: credential.token)
        if var existing = accounts(forHost: host).first(where: { $0.gitCredentialUsername == credential.username
            || $0.login == credential.username }) {
            if existing.signIn == .oauth {
                // A token typed in replaces the OAuth one, and does not expire.
                existing.signIn = .token
            }
            try save(existing, secret: secret)
            setDefault(existing.id, forHost: host)
            return existing
        }
        let kind = HostingKind(HostedRepository.kind(of: host))
        let account = HostingAccount(
            kind: kind, host: host, login: credential.username, gitUsername: credential.username, signIn: .gitPrompt
        )
        try save(account, secret: secret)
        setDefault(account.id, forHost: host)
        return account
    }

    // MARK: Migration

    /// Moves tokens saved one per host by earlier versions into accounts.
    /// An old item goes only once its account is saved, so a failure loses
    /// nothing and the next launch tries again.
    func migrateLegacyTokens() throws {
        let legacy = try secrets.items(service: Self.legacyService)
        guard !legacy.isEmpty else { return }
        let existing = try secrets.items(service: Self.service).compactMap { item in
            item.generic.flatMap { try? JSONDecoder().decode(HostingAccount.self, from: $0) }
        }
        for item in legacy {
            let host = item.account.lowercased()
            let username = item.generic.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let token = String(data: item.data, encoding: .utf8), !token.isEmpty else {
                try secrets.delete(account: item.account, service: Self.legacyService)
                continue
            }
            let alreadyMoved = existing.contains { $0.host == host && $0.gitUsername == username }
            if !alreadyMoved {
                let account = HostingAccount(
                    kind: HostingKind(HostedRepository.kind(of: host)), host: host, login: username,
                    gitUsername: username, signIn: .gitPrompt
                )
                let moved = SecretItem(
                    account: account.id.uuidString,
                    generic: try JSONEncoder().encode(account),
                    data: try JSONEncoder().encode(HostingSecret(token: token))
                )
                try secrets.set(moved, label: "Twig: \(account.title)", service: Self.service)
                if defaultAccountID(forHost: host) == nil {
                    var defaults = preferences.dictionary(forKey: Self.defaultsKey)
                    defaults[host] = account.id.uuidString
                    preferences.set(defaults, forKey: Self.defaultsKey)
                }
            }
            try secrets.delete(account: item.account, service: Self.legacyService)
        }
    }

    // MARK: Support

    private func invalidate() {
        cache.withLock { $0 = nil }
        if let accounts = try? accounts() { publishHostKinds(accounts) }
        changes.changed()
    }

    /// Tells the web links which service each account's host runs.
    private func publishHostKinds(_ accounts: [HostingAccount]) {
        guard self === Self.shared else { return }
        var kinds: [String: HostedRepository.Kind] = [:]
        for account in accounts {
            if let kind = account.kind { kinds[account.host] = kind.linkKind }
        }
        KnownHostKinds.shared.replace(with: kinds)
    }

    /// Runs async work to completion from synchronous code that is allowed
    /// to wait: never call it on the main thread.
    private static func blocking<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) -> Value? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<Value?>(nil)
        Task.detached {
            let value = try? await work()
            result.withLock { $0 = value }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)
        return result.withLock { $0 }
    }
}

/// Counts changes to the accounts, for views to follow.
@MainActor
@Observable
final class AccountChangeCounter {
    static let shared = AccountChangeCounter()
    private(set) var count = 0

    func bump() { count += 1 }
}

/// Lets the account store, which is not on the main actor, tell views.
struct AccountChanges: Sendable {
    func changed() {
        Task { @MainActor in AccountChangeCounter.shared.bump() }
    }
}

/// Supplies an account's token to API requests, refreshing an expiring
/// OAuth token first.
struct AccountTokenSource: TokenSource {
    var account: HostingAccount
    var store: AccountStore

    func authorization() async throws -> HostingAuthorization {
        guard var secret = try store.secret(for: account.id) else { throw HostingError.noAccount(host: account.host) }
        if secret.isExpiring(), secret.refreshToken != nil {
            secret = try await OAuthRefresh.refresh(account, secret: secret, store: store)
        }
        return account.authorization(token: secret.token)
    }
}

extension HostingAccount {
    /// The service for this account.
    func service(store: AccountStore = .shared, transport: any HTTPTransport = URLSessionTransport()) throws -> any HostingService {
        guard let kind, signIn != .gitPrompt else {
            throw HostingError.unsupported(
                "\(title) was saved when a remote asked for a token, so Twig has not signed in to the service with it. "
                    + "Sign in again in Settings, under Accounts."
            )
        }
        return HostingServices.service(
            kind: kind, host: host, scheme: scheme, user: user,
            tokens: AccountTokenSource(account: self, store: store), transport: transport
        )
    }
}
