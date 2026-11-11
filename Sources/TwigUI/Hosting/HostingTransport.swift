import Foundation

/// Sends one HTTP request. The app uses URLSession; tests give recorded
/// responses, so no test reaches a real service.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    var session: URLSession = .shared

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HostingError.invalidResponse }
        return (data, http)
    }
}

/// Why a request to a hosting service failed, in terms the interface can
/// act on.
enum HostingError: LocalizedError, Hashable, Sendable {
    /// The token is missing, expired or revoked.
    case unauthorized(host: String)
    /// The token works but may not do this: usually a missing scope.
    case forbidden(host: String, message: String?)
    case rateLimited(host: String, reset: Date?)
    case notFound(host: String)
    /// The service refused what was asked, saying why.
    case rejected(message: String)
    case offline
    case server(status: Int, message: String?)
    case invalidResponse
    /// The service sent something Twig could not read.
    case unreadable(String)
    case unsupported(String)
    /// No signed-in account can be used for the host.
    case noAccount(host: String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let host):
            "\(host) did not accept the account’s token. It may have expired or been revoked: sign in again in Settings."
        case .forbidden(let host, let message):
            "\(host) refused: \(message ?? "the token is not allowed to do this").\n\nThe token may lack a scope or permission this needs."
        case .rateLimited(let host, let reset):
            "\(host) is limiting how many requests Twig can make."
                + (reset.map { " Try again after \($0.formatted(date: .omitted, time: .shortened))." } ?? " Try again later.")
        case .notFound(let host):
            "\(host) did not find it. It may be private to an account that is not signed in, or it may be gone."
        case .rejected(let message):
            message
        case .offline:
            "The hosting service cannot be reached. Check the network connection."
        case .server(let status, let message):
            "The hosting service failed (HTTP \(status))" + (message.map { ": \($0)" } ?? ".")
        case .invalidResponse:
            "The hosting service sent a response Twig did not expect."
        case .unreadable(let detail):
            "Twig could not read the hosting service’s response: \(detail)"
        case .unsupported(let what):
            what
        case .noAccount(let host):
            "No account is signed in for \(host). Add one in Settings, under Accounts."
        }
    }

    /// Whether signing in again could help.
    var needsSignIn: Bool {
        switch self {
        case .unauthorized, .noAccount: true
        default: false
        }
    }
}

/// How a request proves who it is from.
enum HostingAuthorization: Sendable, Hashable {
    /// `Authorization: Bearer …`.
    case bearer(String)
    /// `Authorization: token …`, Gitea's form for access tokens.
    case token(String)
    /// `Authorization: Basic …`, Bitbucket's for API tokens with an email.
    case basic(username: String, password: String)
    case none

    var headerValue: String? {
        switch self {
        case .bearer(let token): "Bearer \(token)"
        case .token(let token): "token \(token)"
        case .basic(let username, let password): "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case .none: nil
        }
    }
}

/// The token a request uses, fetched as each request goes out so that an
/// expiring one can be refreshed first.
protocol TokenSource: Sendable {
    func authorization() async throws -> HostingAuthorization
}

struct FixedToken: TokenSource {
    var value: HostingAuthorization

    func authorization() async throws -> HostingAuthorization { value }
}

/// A response that decoded, with what its headers say about the next page.
struct HostingResponse<Value> {
    var value: Value
    var http: HTTPURLResponse

    /// The `rel="next"` URL of a `Link` header, as GitHub, GitLab and Gitea
    /// paginate.
    var nextLink: URL? {
        (http.value(forHTTPHeaderField: "Link")).flatMap(HostingClient.nextLink(in:))
    }
}

/// Requests to one service's API: building them, sending them through the
/// transport, mapping failures and decoding answers.
struct HostingClient: Sendable {
    /// `https://api.github.com`, `https://gitlab.example.com/api/v4`…
    var apiBase: URL
    /// The host as people know it, for messages.
    var host: String
    var tokens: any TokenSource
    var transport: any HTTPTransport

    enum Method: String {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
    }

    // MARK: Building

    /// A URL under the API base: `path` is appended as given (already
    /// encoded where needed), with query items.
    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        var string = apiBase.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        string += path.hasPrefix("/") ? path : "/" + path
        var components = URLComponents(string: string)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
            .sorted { $0.name < $1.name }
        if !items.isEmpty {
            components.queryItems = (components.queryItems ?? []) + items
            // `+` would read as a space in a query value.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    func request(_ method: Method, _ url: URL, json: Any? = nil, form: [String: String]? = nil) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let header = try await tokens.authorization().headerValue {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form {
            request.httpBody = Data(Self.formEncode(form).utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30
        return request
    }

    static func formEncode(_ values: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    // MARK: Sending

    /// Sends a request and decodes its JSON answer as `Value`.
    func send<Value: Decodable>(
        _ method: Method, _ url: URL, json: Any? = nil, form: [String: String]? = nil, as type: Value.Type = Value.self
    ) async throws -> HostingResponse<Value> {
        let (data, http) = try await sendRaw(method, url, json: json, form: form)
        do {
            return HostingResponse(value: try Self.decoder.decode(Value.self, from: data), http: http)
        } catch {
            throw HostingError.unreadable(Self.describe(error))
        }
    }

    /// Sends a request whose answer does not matter beyond succeeding.
    @discardableResult
    func sendRaw(
        _ method: Method, _ url: URL, json: Any? = nil, form: [String: String]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try await request(method, url, json: json, form: form)
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(request)
        } catch let error as URLError {
            throw Self.map(error)
        }
        if let error = Self.error(status: http.statusCode, data: data, headers: http, host: host) {
            throw error
        }
        return (data, http)
    }

    // MARK: Errors

    static func map(_ error: URLError) -> any Error {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .timedOut, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            HostingError.offline
        case .cancelled:
            CancellationError()
        default:
            error
        }
    }

    /// The error a response stands for, or `nil` for a success.
    static func error(status: Int, data: Data, headers: HTTPURLResponse, host: String) -> HostingError? {
        guard !(200..<300).contains(status) else { return nil }
        let message = errorMessage(in: data)
        let remaining = headers.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            ?? headers.value(forHTTPHeaderField: "RateLimit-Remaining")
        let reset = (headers.value(forHTTPHeaderField: "X-RateLimit-Reset")
            ?? headers.value(forHTTPHeaderField: "RateLimit-Reset"))
            .flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        let retryAfter = headers.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            .map { Date(timeIntervalSinceNow: $0) }
        switch status {
        case 401:
            return .unauthorized(host: host)
        case 429:
            return .rateLimited(host: host, reset: reset ?? retryAfter)
        case 403 where remaining == "0" || message?.localizedCaseInsensitiveContains("rate limit") == true:
            return .rateLimited(host: host, reset: reset ?? retryAfter)
        case 403:
            return .forbidden(host: host, message: message)
        case 404:
            return .notFound(host: host)
        case 400, 405, 409, 422:
            return .rejected(message: message ?? "\(host) refused the request (HTTP \(status)).")
        default:
            return .server(status: status, message: message)
        }
    }

    /// The human message in an error body. GitHub and Gitea send
    /// `{"message": …, "errors": [{"message": …}]}`, GitLab `{"message": …}`
    /// where the message may be a list or an object of lists, or
    /// `{"error": …, "error_description": …}`, and Bitbucket
    /// `{"error": {"message": …}}`.
    static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty || text.hasPrefix("<") ? nil : String(text.prefix(300))
        }
        var parts: [String] = []
        if let message = flatten(object["message"]) { parts.append(message) }
        if let error = object["error"] as? [String: Any] {
            if let message = flatten(error["message"]) { parts.append(message) }
            if let detail = flatten(error["detail"]) { parts.append(detail) }
        } else if let description = flatten(object["error_description"]) {
            parts.append(description)
        } else if let error = flatten(object["error"]) {
            parts.append(error)
        }
        if let errors = object["errors"] as? [Any] {
            parts += errors.compactMap { item in
                if let item = item as? [String: Any] {
                    return flatten(item["message"]) ?? flatten(item["code"]).map { code in
                        [flatten(item["field"]), code].compactMap { $0 }.joined(separator: " ")
                    }
                }
                return flatten(item)
            }
        }
        let unique = parts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? nil : unique.joined(separator: ". ")
    }

    private static func flatten(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let list as [Any]:
            let parts = list.compactMap { flatten($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case let object as [String: Any]:
            let parts = object.keys.sorted().compactMap { key in flatten(object[key]).map { "\(key) \($0)" } }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default:
            return nil
        }
    }

    // MARK: Pagination

    /// The `rel="next"` URL in a `Link` header:
    /// `<https://…?page=2>; rel="next", <https://…?page=5>; rel="last"`.
    static func nextLink(in header: String) -> URL? {
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = pieces.first, target.hasPrefix("<"), target.hasSuffix(">"),
                  pieces.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == "rel=\"next\"" || $0 == "rel=next" })
            else { continue }
            return URL(string: String(target.dropFirst().dropLast()))
        }
        return nil
    }

    // MARK: Decoding

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = HostingDates.parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date: \(string)")
            }
            return date
        }
        return decoder
    }()

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            "missing “\(key.stringValue)” at \(path(context))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            "unexpected value at \(path(context))"
        case DecodingError.dataCorrupted(let context):
            context.debugDescription
        default:
            error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? "the top" : path
    }
}

/// Dates as the services write them: ISO 8601, with or without fractions
/// of a second (Bitbucket writes six digits), with `Z` or an offset.
enum HostingDates {
    static func parse(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        // Fractions longer than milliseconds: keep three digits.
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let digits = string[string.index(after: dot)...].prefix { $0.isNumber }
        let rest = string[string.index(after: dot)...].dropFirst(digits.count)
        let trimmed = String(string[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
        return fractional.date(from: trimmed)
    }
}

/// A value that may come as a number or a string, as ids do across
/// services and versions.
struct FlexibleID: Decodable, Hashable, Sendable {
    var value: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = String(number)
        } else {
            value = try container.decode(String.self)
        }
    }
}
