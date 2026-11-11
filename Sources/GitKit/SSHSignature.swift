internal import Crypto
import Foundation

/// SSH signatures over arbitrary data, in the format `ssh-keygen -Y sign`
/// writes and git embeds in a commit's `gpgsig` header when `gpg.format`
/// is `ssh` (OpenSSH's PROTOCOL.sshsig).
///
/// The signed blob is the magic preamble, the namespace, an empty reserved
/// field, the hash algorithm's name and the message's hash; the signature
/// wraps that with the signer's public key and is armored in base64.
public enum SSHSignature {
    /// The namespace git signs commits and tags in.
    public static let gitNamespace = "git"

    static let magic = Data("SSHSIG".utf8)
    static let beginMarker = "-----BEGIN SSH SIGNATURE-----"
    static let endMarker = "-----END SSH SIGNATURE-----"

    /// Signs `message` with `key`, returning the armored signature as
    /// `ssh-keygen -Y sign -n <namespace>` prints it, without its last newline.
    public static func sign(_ message: Data, with key: SSHPrivateKey, namespace: String = gitNamespace) throws -> String {
        let hashAlgorithm = "sha512"
        let signed = signedData(message, namespace: namespace, hashAlgorithm: hashAlgorithm)
        var signature = SSHWireWriter()
        signature.write(string: key.kind.algorithm)
        switch key.kind {
        case .ed25519:
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key.rawRepresentation)
            signature.write(string: try privateKey.signature(for: signed))
        case .ecdsaP256:
            let raw = try P256.Signing.PrivateKey(rawRepresentation: key.rawRepresentation).signature(for: signed).rawRepresentation
            signature.write(string: ecdsaBlob(raw))
        case .ecdsaP384:
            let raw = try P384.Signing.PrivateKey(rawRepresentation: key.rawRepresentation).signature(for: signed).rawRepresentation
            signature.write(string: ecdsaBlob(raw))
        case .ecdsaP521:
            let raw = try P521.Signing.PrivateKey(rawRepresentation: key.rawRepresentation).signature(for: signed).rawRepresentation
            signature.write(string: ecdsaBlob(raw))
        }

        var blob = SSHWireWriter()
        blob.write(1)
        blob.write(string: key.publicKey.blob)
        blob.write(string: namespace)
        blob.write(string: Data())
        blob.write(string: hashAlgorithm)
        blob.write(string: signature.data)
        return armor(magic + blob.data)
    }

    /// What an armored signature says, once its signature is checked.
    public struct Verification: Hashable, Sendable {
        /// The key that made the signature.
        public var publicKey: SSHPublicKey
        /// Whether the signature is good for that key and the message.
        public var isValid: Bool
    }

    /// Checks an armored SSH signature over `message`. Throws when the text
    /// is not an SSH signature, or not one made in `namespace`; returns the
    /// signing key and whether the signature holds.
    public static func verify(
        _ armored: String, message: Data, namespace: String = gitNamespace
    ) throws -> Verification {
        let blob = try dearmor(armored)
        var reader = SSHWireReader(blob)
        guard try reader.readBytes(magic.count) == magic, try reader.readUInt32() == 1 else {
            throw SSHSignatureError.malformed
        }
        let keyBlob = try reader.readString()
        var keyReader = SSHWireReader(keyBlob)
        let publicKey = SSHPublicKey(algorithm: try keyReader.readText(), blob: keyBlob)
        guard try reader.readText() == namespace else { throw SSHSignatureError.wrongNamespace }
        _ = try reader.readString()
        let hashAlgorithm = try reader.readText()
        guard hashAlgorithm == "sha512" || hashAlgorithm == "sha256" else {
            throw SSHSignatureError.unsupportedHash(hashAlgorithm)
        }
        var signatureReader = SSHWireReader(try reader.readString())
        let signatureAlgorithm = try signatureReader.readText()
        let signatureBytes = try signatureReader.readString()
        guard signatureAlgorithm == publicKey.algorithm, let kind = publicKey.kind else {
            throw SSHSignatureError.unsupportedKey(signatureAlgorithm)
        }
        let signed = signedData(message, namespace: namespace, hashAlgorithm: hashAlgorithm)
        let isValid = (try? isValidSignature(signatureBytes, kind: kind, keyBlob: keyBlob, over: signed)) ?? false
        return Verification(publicKey: publicKey, isValid: isValid)
    }

    /// Whether `text` holds an armored SSH signature.
    public static func isSSHSignature(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(beginMarker)
    }

    // MARK: Pieces

    static func signedData(_ message: Data, namespace: String, hashAlgorithm: String) -> Data {
        let digest = hashAlgorithm == "sha256" ? Data(SHA256.hash(data: message)) : Data(SHA512.hash(data: message))
        var writer = SSHWireWriter()
        writer.write(string: namespace)
        writer.write(string: Data())
        writer.write(string: hashAlgorithm)
        writer.write(string: digest)
        return magic + writer.data
    }

    private static func isValidSignature(_ signature: Data, kind: SSHKeyKind, keyBlob: Data, over signed: Data) throws -> Bool {
        var reader = SSHWireReader(keyBlob)
        _ = try reader.readText()
        if kind == .ed25519 {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: try reader.readString())
            return key.isValidSignature(signature, for: signed)
        }
        guard try reader.readText() == kind.curveName else { return false }
        let point = try reader.readString()
        var parts = SSHWireReader(signature)
        let r = try parts.readUnsignedMPInt()
        let s = try parts.readUnsignedMPInt()
        let length = kind.privateKeyLength
        guard r.count <= length, s.count <= length else { return false }
        let raw = Data(repeating: 0, count: length - r.count) + r + Data(repeating: 0, count: length - s.count) + s
        switch kind {
        case .ecdsaP256:
            return try P256.Signing.PublicKey(x963Representation: point)
                .isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: signed)
        case .ecdsaP384:
            return try P384.Signing.PublicKey(x963Representation: point)
                .isValidSignature(try P384.Signing.ECDSASignature(rawRepresentation: raw), for: signed)
        case .ecdsaP521:
            return try P521.Signing.PublicKey(x963Representation: point)
                .isValidSignature(try P521.Signing.ECDSASignature(rawRepresentation: raw), for: signed)
        case .ed25519:
            return false
        }
    }

    /// An ECDSA signature as SSH writes it: `r` and `s` as two `mpint`s.
    private static func ecdsaBlob(_ raw: Data) -> Data {
        let half = raw.count / 2
        var writer = SSHWireWriter()
        writer.write(string: mpint(raw.prefix(half)))
        writer.write(string: mpint(raw.suffix(half)))
        return writer.data
    }

    /// A positive big-endian number as an `mpint`: no leading zeros, but a
    /// zero byte in front when the top bit is set, or it would read as negative.
    private static func mpint(_ bytes: Data) -> Data {
        var bytes = Data(bytes.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return bytes
    }

    /// Base64 in lines of 70 characters between the markers, as ssh-keygen writes it.
    private static func armor(_ blob: Data) -> String {
        let encoded = blob.base64EncodedString()
        var lines: [String] = [beginMarker]
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 70, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    private static func dearmor(_ armored: String) throws -> Data {
        let lines = armored.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(of: beginMarker),
              let end = lines.firstIndex(of: endMarker), begin < end,
              let blob = Data(base64Encoded: lines[(begin + 1)..<end].joined()) else {
            throw SSHSignatureError.malformed
        }
        return blob
    }
}

/// A signature that cannot be read as an SSH signature.
public enum SSHSignatureError: Error, Hashable, Sendable, LocalizedError {
    case malformed
    /// Made for another purpose than signing git objects.
    case wrongNamespace
    case unsupportedHash(String)
    case unsupportedKey(String)

    public var errorDescription: String? {
        switch self {
        case .malformed: "The signature is damaged or not an SSH signature."
        case .wrongNamespace: "The signature was not made for git."
        case .unsupportedHash(let name): "The signature uses the hash \(name), which Wye can’t check."
        case .unsupportedKey(let name): "The signature was made with a \(name) key, which Wye can’t check."
        }
    }
}

// MARK: Allowed signers

/// A key trusted to sign as someone: a line of an `allowed_signers` file,
/// as `gpg.ssh.allowedSignersFile` names, or one of the app's own keys.
public struct AllowedSigner: Hashable, Sendable, Codable, Identifiable {
    /// Who signs with the key, usually an email address. A file's line can
    /// name several, separated by commas.
    public var principal: String
    /// `ssh-ed25519 AAAA…`.
    public var publicKey: String

    public var id: String { principal + " " + publicKey }

    public init(principal: String, publicKey: String) {
        self.principal = principal
        self.publicKey = publicKey
    }

    /// The parsed key, or `nil` for a line that is not one.
    public var key: SSHPublicKey? { try? SSHPublicKey(openSSH: publicKey) }

    /// Reads an `allowed_signers` file: one `principals [options] keytype
    /// key [comment]` per line, `#` comments and blank lines skipped. Lines
    /// whose key Wye cannot read, or whose options limit them to other
    /// namespaces than git's, are left out.
    public static func parse(_ text: String) -> [AllowedSigner] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let fields = Self.fields(trimmed)
            guard fields.count >= 3 else { return nil }
            // The key type comes right after the principals, or after the options.
            let typeIndex = SSHKeyKind(algorithm: fields[1]) != nil ? 1 : 2
            guard fields.count > typeIndex + 1, SSHKeyKind(algorithm: fields[typeIndex]) != nil else { return nil }
            if typeIndex == 2, let namespaces = option("namespaces", in: fields[1]),
               !namespaces.split(separator: ",").contains(where: { $0 == "git" || $0 == "*" }) {
                return nil
            }
            let keyLine = fields[typeIndex] + " " + fields[typeIndex + 1]
            guard (try? SSHPublicKey(openSSH: keyLine)) != nil else { return nil }
            return AllowedSigner(principal: fields[0], publicKey: keyLine)
        }
    }

    /// Splits on spaces outside double quotes, which option values may use.
    private static func fields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isQuoted = false
        for character in line {
            if character == "\"" { isQuoted.toggle() }
            if character.isWhitespace, !isQuoted {
                if !current.isEmpty { fields.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { fields.append(current) }
        return fields
    }

    private static func option(_ name: String, in options: String) -> String? {
        // A value is quoted and may hold commas itself, as `namespaces="git,file"`.
        guard let start = options.range(of: name + "=\"", options: .caseInsensitive) else { return nil }
        let rest = options[start.upperBound...]
        return String(rest.prefix { $0 != "\"" })
    }
}
