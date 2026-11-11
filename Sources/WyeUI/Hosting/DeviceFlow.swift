import Foundation

/// The OAuth applications Wye signs in with, by host.
///
/// Signing in with the device flow needs an OAuth application registered
/// with the service by whoever publishes the app. Their client ids go in
/// the app's Info.plist under `WyeOAuthClientIDs`, a dictionary from host
/// to client id, empty by default; the device flow is offered only for a
/// host with an id. A client id is not secret: device flow applications
/// have no client secret.
enum OAuthConfiguration {
    static let infoKey = "WyeOAuthClientIDs"

    /// The configured client id for a host, if any.
    static func clientID(forHost host: String, info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let ids = info?[infoKey] as? [String: Any],
              let id = (ids[host.lowercased()] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            return nil
        }
        return id
    }

    /// Whether a service has a device flow at all: Bitbucket Cloud and
    /// Gitea or Forgejo do not.
    static func supportsDeviceFlow(_ kind: HostingKind) -> Bool {
        kind == .github || kind == .gitlab
    }

    static func scopes(for kind: HostingKind) -> String {
        switch kind {
        case .github: "repo read:org"
        case .gitlab: "api write_repository"
        case .bitbucket, .gitea: ""
        }
    }

    /// Where the device flow starts and where its token is collected.
    static func endpoints(kind: HostingKind, host: String, scheme: String = "https") -> (code: URL, token: URL)? {
        let base = "\(scheme)://\(host.lowercased())"
        switch kind {
        case .github:
            return (URL(string: base + "/login/device/code")!, URL(string: base + "/login/oauth/access_token")!)
        case .gitlab:
            return (URL(string: base + "/oauth/authorize_device")!, URL(string: base + "/oauth/token")!)
        case .bitbucket, .gitea:
            return nil
        }
    }
}

/// The code a person types at the service to let Wye in.
struct DeviceAuthorization: Hashable, Sendable {
    var deviceCode: String
    var userCode: String
    var verificationURL: URL
    /// The page with the code already filled in, where the service has one.
    var completeVerificationURL: URL?
    var expiresAt: Date
    var interval: TimeInterval
}

/// The OAuth 2.0 device authorization grant (RFC 8628), as GitHub and
/// GitLab offer it.
struct DeviceFlow: Sendable {
    var kind: HostingKind
    var host: String
    var scheme: String = "https"
    var clientID: String
    var transport: any HTTPTransport

    private static let grantType = "urn:ietf:params:oauth:grant-type:device_code"

    /// Asks for a code to show.
    func start(now: Date = .now) async throws -> DeviceAuthorization {
        guard let endpoints = OAuthConfiguration.endpoints(kind: kind, host: host, scheme: scheme) else {
            throw HostingError.unsupported("\(kind.title) has no device sign-in.")
        }
        let response = try await post(endpoints.code, [
            "client_id": clientID, "scope": OAuthConfiguration.scopes(for: kind)
        ])
        guard let device = response["device_code"] as? String, let user = response["user_code"] as? String,
              let uri = (response["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw HostingError.rejected(message: Self.message(in: response) ?? "\(host) did not start the sign-in.")
        }
        return DeviceAuthorization(
            deviceCode: device,
            userCode: user,
            verificationURL: uri,
            completeVerificationURL: (response["verification_uri_complete"] as? String).flatMap(URL.init(string:)),
            expiresAt: now.addingTimeInterval(Self.number(response["expires_in"]) ?? 900),
            interval: Self.number(response["interval"]) ?? 5
        )
    }

    /// One poll's answer.
    enum PollResult: Hashable, Sendable {
        case pending
        /// The service asks Wye to poll less often, every this many seconds.
        case slowDown(TimeInterval)
        case authorized(HostingSecret)
    }

    /// Asks once whether the person has let Wye in.
    func poll(_ authorization: DeviceAuthorization, now: Date = .now) async throws -> PollResult {
        guard let endpoints = OAuthConfiguration.endpoints(kind: kind, host: host, scheme: scheme) else {
            throw HostingError.unsupported("\(kind.title) has no device sign-in.")
        }
        let response = try await post(endpoints.token, [
            "client_id": clientID, "device_code": authorization.deviceCode, "grant_type": Self.grantType
        ])
        if let token = response["access_token"] as? String {
            return .authorized(Self.secret(token: token, response: response, now: now))
        }
        switch response["error"] as? String {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown(Self.number(response["interval"]) ?? authorization.interval + 5)
        case "expired_token":
            throw HostingError.rejected(message: "The code expired before it was entered. Start again.")
        case "access_denied":
            throw CancellationError()
        default:
            throw HostingError.rejected(message: Self.message(in: response) ?? "\(host) did not sign Wye in.")
        }
    }

    /// Polls until the person lets Wye in, refuses, or the code expires.
    func waitForAuthorization(_ authorization: DeviceAuthorization) async throws -> HostingSecret {
        var interval = authorization.interval
        while Date.now < authorization.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            switch try await poll(authorization) {
            case .pending: continue
            case .slowDown(let next): interval = next
            case .authorized(let secret): return secret
            }
        }
        throw HostingError.rejected(message: "The code expired before it was entered. Start again.")
    }

    // MARK: Support

    /// Posts a form and reads the JSON answer, error or not: the token
    /// endpoint says "pending" with an error status on GitLab and with 200
    /// on GitHub.
    private func post(_ url: URL, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(HostingClient.formEncode(form).utf8)
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(request)
        } catch let error as URLError {
            throw HostingClient.map(error)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let error = HostingClient.error(status: http.statusCode, data: data, headers: http, host: host) {
                throw error
            }
            throw HostingError.invalidResponse
        }
        if http.statusCode >= 500 {
            throw HostingError.server(status: http.statusCode, message: Self.message(in: object))
        }
        return object
    }

    static func secret(token: String, response: [String: Any], now: Date) -> HostingSecret {
        HostingSecret(
            token: token,
            refreshToken: response["refresh_token"] as? String,
            expiresAt: number(response["expires_in"]).map { now.addingTimeInterval($0) }
        )
    }

    private static func message(in response: [String: Any]) -> String? {
        (response["error_description"] as? String) ?? (response["error"] as? String)
    }

    static func number(_ value: Any?) -> TimeInterval? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: TimeInterval(string)
        default: nil
        }
    }
}

/// Renews an expiring OAuth token with its refresh token (GitLab's last
/// two hours), saving the new one.
enum OAuthRefresh {
    static func refresh(
        _ account: HostingAccount, secret: HostingSecret, store: AccountStore,
        transport: any HTTPTransport = URLSessionTransport(), now: Date = .now
    ) async throws -> HostingSecret {
        guard let kind = account.kind, let refreshToken = secret.refreshToken,
              let clientID = OAuthConfiguration.clientID(forHost: account.host),
              let endpoints = OAuthConfiguration.endpoints(kind: kind, host: account.host, scheme: account.scheme) else {
            throw HostingError.unauthorized(host: account.host)
        }
        var request = URLRequest(url: endpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(HostingClient.formEncode([
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken
        ]).utf8)
        let (data, http) = try await transport.send(request)
        guard (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String else {
            throw HostingError.unauthorized(host: account.host)
        }
        var renewed = DeviceFlow.secret(token: token, response: object, now: now)
        if renewed.refreshToken == nil { renewed.refreshToken = refreshToken }
        try store.save(account, secret: renewed)
        return renewed
    }
}
