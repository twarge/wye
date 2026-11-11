import Foundation

/// Where an SSH remote is: `ssh://[user@]host[:port]/path`, its `ssh+git://`
/// and `git+ssh://` spellings, or the scp-like `[user@]host:path`, read the
/// way libgit2 and git read them.
struct SSHAddress: Hashable, Sendable {
    var username: String?
    var host: String
    var port: Int
    /// The repository's path on the host, as the remote command is given it.
    var path: String

    /// The name to log in as when the address gives none: the one the
    /// hosting services all use.
    static let defaultUsername = "git"

    init(username: String?, host: String, port: Int = 22, path: String) {
        self.username = username
        self.host = host
        self.port = port
        self.path = path
    }

    init(_ url: String) throws {
        let invalid = RemoteError.invalidSSHAddress(url)
        if let schemeEnd = url.range(of: "://") {
            let scheme = url[..<schemeEnd.lowerBound].lowercased()
            guard ["ssh", "ssh+git", "git+ssh"].contains(scheme) else { throw invalid }
            let rest = url[schemeEnd.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var authority = rest[..<slash]
            var path = String(rest[slash...])
            if authority.isEmpty || path.isEmpty { throw invalid }
            // `ssh://host/~user/repo` is relative to a home folder, as in git.
            if path.hasPrefix("/~") { path.removeFirst() }

            var username: String?
            if let at = authority.lastIndex(of: "@") {
                username = String(authority[..<at]).removingPercentEncoding ?? String(authority[..<at])
                authority = authority[authority.index(after: at)...]
            }
            let (host, port) = try Self.hostAndPort(authority, invalid: invalid)
            self.init(username: username.flatMap { $0.isEmpty ? nil : $0 }, host: host, port: port, path: path)
            return
        }

        // scp-like: the first colon outside brackets ends the host.
        var depth = 0
        var colon: String.Index?
        for index in url.indices {
            switch url[index] {
            case "[": depth += 1
            case "]": depth -= 1
            case ":" where depth == 0: colon = index
            default: break
            }
            if colon != nil { break }
        }
        guard let colon else { throw invalid }
        var authority = url[..<colon]
        let path = String(url[url.index(after: colon)...])
        guard !path.isEmpty, !authority.contains("/") else { throw invalid }
        var username: String?
        if let at = authority.lastIndex(of: "@"), !authority[..<at].contains("[") {
            username = String(authority[..<at])
            authority = authority[authority.index(after: at)...]
        }
        var host = String(authority), port = 22
        // `[host:port]:path` gives a port; `[::1]:path` is an IPv6 address.
        if host.hasPrefix("["), host.hasSuffix("]") {
            let inside = host.dropFirst().dropLast()
            if inside.filter({ $0 == ":" }).count == 1, let separator = inside.lastIndex(of: ":"),
               let number = Int(inside[inside.index(after: separator)...]) {
                host = String(inside[..<separator])
                port = number
            } else {
                host = String(inside)
            }
        }
        guard !host.isEmpty, (1...65535).contains(port) else { throw invalid }
        self.init(username: username.flatMap { $0.isEmpty ? nil : $0 }, host: host, port: port, path: path)
    }

    private static func hostAndPort(_ authority: Substring, invalid: RemoteError) throws -> (String, Int) {
        var host = authority
        var port = 22
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw invalid }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let number = Int(after.dropFirst()) else { throw invalid }
                port = number
            }
        } else if let separator = authority.lastIndex(of: ":") {
            host = authority[..<separator]
            let digits = authority[authority.index(after: separator)...]
            if !digits.isEmpty {
                guard let number = Int(digits) else { throw invalid }
                port = number
            }
        }
        let name = String(host).removingPercentEncoding ?? String(host)
        guard !name.isEmpty, (1...65535).contains(port) else { throw invalid }
        return (name, port)
    }

    var loginName: String { username ?? Self.defaultUsername }

    /// The command the server runs, such as `git-upload-pack '/srv/project.git'`.
    func command(_ program: String) -> String {
        "\(program) \(Self.quote(path))"
    }

    /// Quotes for a POSIX shell as git does: in single quotes, with `'` and
    /// `!` taken out of them and escaped.
    static func quote(_ text: String) -> String {
        var quoted = "'"
        for character in text {
            switch character {
            case "'": quoted += "'\\''"
            case "!": quoted += "'\\!'"
            default: quoted.append(character)
            }
        }
        return quoted + "'"
    }

    /// Whether a remote URL is one of SSH's.
    static func isSSH(_ url: String) -> Bool {
        if let schemeEnd = url.range(of: "://") {
            return ["ssh", "ssh+git", "git+ssh"].contains(url[..<schemeEnd.lowerBound].lowercased())
        }
        return Repository.isSCPLike(url)
    }
}
