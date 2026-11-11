import Foundation
import Synchronization
@testable import WyeUI

/// A transport that answers from recorded responses and keeps every
/// request, so tests check what was asked without reaching a service.
final class StubTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int = 200
        var body: Data
        var headers: [String: String] = [:]
    }

    /// Matches a request; the first route that matches answers it.
    struct Route: Sendable {
        var method: String
        /// The URL's path and query must contain this.
        var contains: String
        var reply: Reply
        /// Answered once, then skipped, for sequences such as polling.
        var once = false
    }

    private let state = Mutex<(routes: [Route], requests: [URLRequest])>(([], []))

    var requests: [URLRequest] { state.withLock { $0.requests } }

    /// Answers `method` requests whose URL contains `contains` with JSON.
    func on(
        _ method: String, _ contains: String, status: Int = 200, json: String, headers: [String: String] = [:],
        once: Bool = false
    ) {
        let route = Route(
            method: method, contains: contains,
            reply: Reply(status: status, body: Data(json.utf8), headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }),
            once: once
        )
        state.withLock { $0.routes.append(route) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let target = url.absoluteString
        let reply: Reply? = state.withLock { state in
            state.requests.append(request)
            guard let index = state.routes.firstIndex(where: {
                $0.method == request.httpMethod && target.contains($0.contains)
            }) else { return nil }
            let route = state.routes[index]
            if route.once { state.routes.remove(at: index) }
            return route.reply
        }
        guard let reply else {
            return (Data(#"{"message":"Not Found"}"#.utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (reply.body, HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }

    /// The last request whose URL contains `fragment`.
    func last(_ method: String, _ fragment: String) -> URLRequest? {
        requests.last { $0.httpMethod == method && $0.url!.absoluteString.contains(fragment) }
    }
}

/// A transport that fails as an offline device does.
struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

extension URLRequest {
    /// The JSON body as a dictionary.
    var jsonBody: [String: Any]? {
        httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The form body as a dictionary.
    var formBody: [String: String] {
        guard let body = httpBody.flatMap({ String(data: $0, encoding: .utf8) }) else { return [:] }
        var values: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            values[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return values
    }

    /// A query item of the URL.
    func query(_ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == name }?.value
    }
}

/// A service over the stub, signed in as `user`.
func stubService(
    _ kind: HostingKind, host: String? = nil, user: HostingUser? = HostingUser(login: "octo"),
    transport: StubTransport, authorization: HostingAuthorization = .bearer("secret")
) -> any HostingService {
    HostingServices.service(
        kind: kind, host: host ?? kind.defaultHost, user: user, tokens: FixedToken(value: authorization),
        transport: transport
    )
}
