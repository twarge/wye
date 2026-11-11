internal import Crypto
import Foundation

/// The kinds of key Twig signs SSH logins with: the ones SSH's Swift
/// implementation supports. RSA is not among them.
public enum SSHKeyKind: String, Hashable, Sendable, Codable, CaseIterable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521

    /// The algorithm's name in SSH, as the first word of a public key line.
    public var algorithm: String {
        switch self {
        case .ed25519: "ssh-ed25519"
        case .ecdsaP256: "ecdsa-sha2-nistp256"
        case .ecdsaP384: "ecdsa-sha2-nistp384"
        case .ecdsaP521: "ecdsa-sha2-nistp521"
        }
    }

    /// How the interface names it.
    public var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsaP256: "ECDSA P-256"
        case .ecdsaP384: "ECDSA P-384"
        case .ecdsaP521: "ECDSA P-521"
        }
    }

    init?(algorithm: String) {
        guard let kind = Self.allCases.first(where: { $0.algorithm == algorithm }) else { return nil }
        self = kind
    }

    /// The curve's name inside an ECDSA key blob.
    var curveName: String? {
        switch self {
        case .ed25519: nil
        case .ecdsaP256: "nistp256"
        case .ecdsaP384: "nistp384"
        case .ecdsaP521: "nistp521"
        }
    }

    /// The length of the private scalar, which an `mpint` may write shorter.
    var privateKeyLength: Int {
        switch self {
        case .ed25519, .ecdsaP256: 32
        case .ecdsaP384: 48
        case .ecdsaP521: 66
        }
    }
}

/// Why a key could not be read or used.
public enum SSHKeyError: Error, Hashable, Sendable, LocalizedError {
    /// Not an OpenSSH private key, or a damaged one.
    case invalidFormat
    /// An RSA key, which Twig cannot sign with.
    case rsaNotSupported
    /// Another kind of key, such as DSA or a security key; the algorithm's name.
    case unsupportedKind(String)
    /// The key is protected by a passphrase and none was given.
    case passphraseRequired
    case wrongPassphrase
    /// Encrypted with a cipher or key derivation Twig does not implement.
    case unsupportedEncryption(String)
    /// The file holds more than one key.
    case multipleKeys

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "This is not an OpenSSH private key. It should begin with “-----BEGIN OPENSSH PRIVATE KEY-----”."
        case .rsaNotSupported:
            "This is an RSA key, which Twig can’t use. Create an Ed25519 key in Twig, or use an Ed25519 or ECDSA key of your own."
        case .unsupportedKind(let name):
            "Twig can’t use \(name) keys. Use an Ed25519 or ECDSA key."
        case .passphraseRequired:
            "This key is protected by a passphrase."
        case .wrongPassphrase:
            "The passphrase is not right for this key."
        case .unsupportedEncryption(let name):
            "This key is encrypted with \(name), which Twig can’t read. Remove its passphrase with ssh-keygen -p first, then import it."
        case .multipleKeys:
            "The file holds more than one key. Import one key at a time."
        }
    }
}

/// A public key as SSH writes it: the algorithm and the key's wire-format blob.
public struct SSHPublicKey: Hashable, Sendable {
    /// Such as `ssh-ed25519`.
    public let algorithm: String
    /// The key in SSH's wire format, which the fingerprint is taken over.
    public let blob: Data

    init(algorithm: String, blob: Data) {
        self.algorithm = algorithm
        self.blob = blob
    }

    /// Reads a line such as `ssh-ed25519 AAAA… comment`, the comment ignored.
    public init(openSSH line: String) throws {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
            throw SSHKeyError.invalidFormat
        }
        var reader = SSHWireReader(blob)
        guard try reader.readText() == String(fields[0]) else { throw SSHKeyError.invalidFormat }
        self.init(algorithm: String(fields[0]), blob: blob)
    }

    public var kind: SSHKeyKind? { SSHKeyKind(algorithm: algorithm) }

    /// `ssh-ed25519 AAAA…`, what a hosting service wants pasted in.
    public var openSSH: String {
        "\(algorithm) \(blob.base64EncodedString())"
    }

    /// `SHA256:…`, as ssh and ssh-keygen show it.
    public var fingerprint: String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// The interface's name for the kind of key, such as `Ed25519`.
    public var displayName: String {
        kind?.displayName ?? algorithm
    }
}

/// A private key to log in to SSH hosts with.
///
/// The key material is kept as CryptoKit's raw representation, so that the
/// value can be stored and passed around without any of the SSH library's
/// types. Its description never shows the key.
public struct SSHPrivateKey: Hashable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let kind: SSHKeyKind
    /// Ed25519's 32-byte seed, or the ECDSA private scalar.
    public let rawRepresentation: Data
    public var comment: String

    /// Checks that the material is a valid key of that kind.
    public init(kind: SSHKeyKind, rawRepresentation: Data, comment: String = "") throws {
        self.kind = kind
        self.rawRepresentation = rawRepresentation
        self.comment = comment
        _ = try publicKeyBlob()
    }

    /// A new Ed25519 key.
    public static func generateEd25519(comment: String) -> SSHPrivateKey {
        // A fresh key's raw representation is always valid.
        try! SSHPrivateKey(
            kind: .ed25519, rawRepresentation: Curve25519.Signing.PrivateKey().rawRepresentation, comment: comment
        )
    }

    /// Reads an OpenSSH private key file (`-----BEGIN OPENSSH PRIVATE KEY-----`),
    /// decrypting it with `passphrase` if it has one.
    public init(openSSHPrivateKey text: String, passphrase: String? = nil) throws {
        self = try OpenSSHPrivateKeyFile.read(text, passphrase: passphrase)
    }

    /// Whether an OpenSSH private key file is protected by a passphrase.
    public static func isEncrypted(openSSHPrivateKey text: String) throws -> Bool {
        try OpenSSHPrivateKeyFile.isEncrypted(text)
    }

    public var publicKey: SSHPublicKey {
        // `init` has checked the material.
        SSHPublicKey(algorithm: kind.algorithm, blob: try! publicKeyBlob())
    }

    /// The public key line with the comment, as `ssh-keygen -y` writes it.
    public var openSSHPublicKey: String {
        comment.isEmpty ? publicKey.openSSH : publicKey.openSSH + " " + comment
    }

    public var description: String {
        "SSHPrivateKey(\(kind.displayName), \(publicKey.fingerprint))"
    }

    public var debugDescription: String { description }

    private func publicKeyBlob() throws -> Data {
        var writer = SSHWireWriter()
        writer.write(string: kind.algorithm)
        switch kind {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
            writer.write(string: key.publicKey.rawRepresentation)
        case .ecdsaP256:
            writer.write(string: kind.curveName!)
            writer.write(string: try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation).publicKey.x963Representation)
        case .ecdsaP384:
            writer.write(string: kind.curveName!)
            writer.write(string: try P384.Signing.PrivateKey(rawRepresentation: rawRepresentation).publicKey.x963Representation)
        case .ecdsaP521:
            writer.write(string: kind.curveName!)
            writer.write(string: try P521.Signing.PrivateKey(rawRepresentation: rawRepresentation).publicKey.x963Representation)
        }
        return writer.data
    }
}
