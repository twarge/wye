import Foundation
import Synchronization

/// The key an SSH server presented for itself.
public struct SSHHostKey: Hashable, Sendable {
    public var host: String
    public var port: Int
    public var publicKey: SSHPublicKey

    public init(host: String, port: Int, publicKey: SSHPublicKey) {
        self.host = host
        self.port = port
        self.publicKey = publicKey
    }

    /// Such as `ssh-ed25519`.
    public var algorithm: String { publicKey.algorithm }
    /// `SHA256:…`.
    public var fingerprint: String { publicKey.fingerprint }
    /// `ssh-ed25519 AAAA…`.
    public var openSSH: String { publicKey.openSSH }

    /// `host`, or `[host]:port` off the standard port, as known_hosts names it.
    public var hostPattern: String {
        KnownHosts.pattern(host: host, port: port)
    }
}

/// What the known hosts say about a host key.
public enum SSHHostKeyTrust: Hashable, Sendable {
    case trusted
    /// The host is not known, or not with a key of this type.
    case unknown
    /// The host is known with another key of the same type. Either the
    /// server's key was replaced, or something is impersonating it.
    case mismatch(known: SSHPublicKey)
}

/// Decides whether to trust the key an SSH server presents.
///
/// Asked in the middle of connecting, on the repository's thread, so it
/// answers at once from storage, as ``CredentialProvider`` does: an unknown
/// or changed key fails the operation, and the caller asks the user.
public protocol SSHHostKeyValidator: Sendable {
    func trust(for hostKey: SSHHostKey) -> SSHHostKeyTrust
}

/// Trusted host keys, in a file in OpenSSH's known_hosts format.
///
/// Only plain host names are written and read: hashed names, wildcards and
/// markers in a file written by hand are skipped. A few hosting services'
/// published keys are trusted from the start; see ``builtIn``.
public final class KnownHosts: SSHHostKeyValidator {
    public struct Entry: Hashable, Sendable, Identifiable {
        /// `host` or `[host]:port`.
        public var pattern: String
        public var publicKey: SSHPublicKey
        /// Whether it is one of Twig's own, which cannot be removed.
        public var isBuiltIn: Bool

        public var id: String { pattern + " " + publicKey.openSSH }
    }

    /// The Ed25519 and ECDSA host keys GitHub, GitLab and Bitbucket publish
    /// in their documentation, checked against the fingerprints they give.
    public static let builtIn: [Entry] = [
        "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl",
        "github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=",
        "gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf",
        "gitlab.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFSMqzJeV9rUzU4kWitGjeR4PWSa29SPqJ1fVkhtj3Hw9xjLVXVYrU9QlYWrOLXBpQ6KWjbjTDTdDkoohFzgbEY=",
        "bitbucket.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIazEu89wgQZ4bqs3d63QSMzYVa0MuJ2e2gKTKqu+UUO",
        "bitbucket.org ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBPIQmuzMBuKdWeF4+a2sjSSpBK0iqitSQ+5BM9KhpexuGt20JpTVM7u5BDZngncgrqDMbWdxMWWOGtZ9UgbqgZE="
    ].compactMap { line in
        parse(line).map { Entry(pattern: $0.pattern, publicKey: $0.key, isBuiltIn: true) }
    }

    public let file: URL
    private let includesBuiltIn: Bool
    private let lock = Mutex<Void>(())

    /// `includeBuiltIn: false` leaves out ``builtIn``, for tests.
    public init(file: URL, includeBuiltIn: Bool = true) {
        self.file = file
        includesBuiltIn = includeBuiltIn
    }

    public func trust(for hostKey: SSHHostKey) -> SSHHostKeyTrust {
        let pattern = hostKey.hostPattern
        let known = entries().filter { $0.pattern == pattern && $0.publicKey.algorithm == hostKey.algorithm }
        if known.contains(where: { $0.publicKey == hostKey.publicKey }) { return .trusted }
        if let other = known.first { return .mismatch(known: other.publicKey) }
        return .unknown
    }

    /// Every trusted key, Twig's own first.
    public func entries() -> [Entry] {
        let saved = lock.withLock { _ in readLines() }.compactMap { line in
            Self.parse(line).map { Entry(pattern: $0.pattern, publicKey: $0.key, isBuiltIn: false) }
        }
        return (includesBuiltIn ? Self.builtIn : []) + saved
    }

    /// Trusts a host's key from now on, in place of any other key of the
    /// same type the host had.
    public func trust(_ hostKey: SSHHostKey) throws {
        try lock.withLock { _ in
            let pattern = hostKey.hostPattern
            var lines = readLines().filter { line in
                guard let entry = Self.parse(line) else { return true }
                return !(entry.pattern == pattern && entry.key.algorithm == hostKey.algorithm)
            }
            lines.append("\(pattern) \(hostKey.openSSH)")
            try write(lines)
        }
    }

    /// Stops trusting a saved key. Twig's own cannot be removed.
    public func remove(_ entry: Entry) throws {
        try lock.withLock { _ in
            let lines = readLines().filter { line in
                guard let parsed = Self.parse(line) else { return true }
                return !(parsed.pattern == entry.pattern && parsed.key == entry.publicKey)
            }
            try write(lines)
        }
    }

    // MARK: File

    private func readLines() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func write(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func pattern(host: String, port: Int) -> String {
        let host = host.lowercased()
        return port == 22 ? host : "[\(host)]:\(port)"
    }

    /// One line's host and key; a line naming several hosts gives the first.
    /// `nil` for comments, markers, hashed names and anything unreadable.
    static func parse(_ line: String) -> (pattern: String, key: SSHPublicKey)? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 3, !fields[0].hasPrefix("#"), !fields[0].hasPrefix("@"), !fields[0].hasPrefix("|"),
              let key = try? SSHPublicKey(openSSH: "\(fields[1]) \(fields[2])") else { return nil }
        let pattern = fields[0].split(separator: ",").first.map { String($0).lowercased() } ?? ""
        guard !pattern.isEmpty, !pattern.contains("*"), !pattern.contains("?") else { return nil }
        return (pattern, key)
    }
}
