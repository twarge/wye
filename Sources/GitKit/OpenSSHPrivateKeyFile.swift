import CommonCrypto
internal import Crypto
import Foundation

/// OpenSSH's private key file, `openssh-key-v1` in a PEM-style armour, as
/// `ssh-keygen` writes it. Older PEM files of ECDSA keys are read too.
enum OpenSSHPrivateKeyFile {
    private static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let end = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = Data("openssh-key-v1\0".utf8)

    /// The parts before the private section, which is the only encrypted one.
    private struct Envelope {
        var cipher: String
        var kdf: String
        var kdfOptions: Data
        var publicKey: SSHPublicKey
        var encrypted: Data
        /// The authentication tag after the private section, for AES-GCM.
        var trailer: Data
    }

    static func isEncrypted(_ text: String) throws -> Bool {
        if let pem = try readLegacyPEM(text, passphrase: nil, checkOnly: true) { return pem.isEncrypted }
        return try envelope(text).cipher != "none"
    }

    static func read(_ text: String, passphrase: String?) throws -> SSHPrivateKey {
        if let pem = try readLegacyPEM(text, passphrase: passphrase, checkOnly: false), let key = pem.key {
            return key
        }
        let envelope = try envelope(text)
        let section: Data
        if envelope.cipher == "none" {
            section = envelope.encrypted
        } else {
            guard let passphrase, !passphrase.isEmpty else { throw SSHKeyError.passphraseRequired }
            section = try decrypt(envelope, passphrase: passphrase)
        }

        var reader = SSHWireReader(section)
        let check1 = try reader.readUInt32(), check2 = try reader.readUInt32()
        // The two words match only if the decryption worked.
        guard check1 == check2 else {
            throw envelope.cipher == "none" ? SSHKeyError.invalidFormat : SSHKeyError.wrongPassphrase
        }
        let algorithm = try reader.readText()
        guard let kind = SSHKeyKind(algorithm: algorithm) else { throw unsupported(algorithm) }
        let raw: Data
        switch kind {
        case .ed25519:
            _ = try reader.readString()
            let secret = try reader.readString()
            guard secret.count == 64 else { throw SSHKeyError.invalidFormat }
            raw = secret.prefix(32)
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            guard try reader.readText() == kind.curveName else { throw SSHKeyError.invalidFormat }
            _ = try reader.readString()
            let scalar = try reader.readUnsignedMPInt()
            guard scalar.count <= kind.privateKeyLength else { throw SSHKeyError.invalidFormat }
            raw = Data(repeating: 0, count: kind.privateKeyLength - scalar.count) + scalar
        }
        let comment = (try? reader.readText()) ?? ""
        let key: SSHPrivateKey
        do {
            key = try SSHPrivateKey(kind: kind, rawRepresentation: raw, comment: comment)
        } catch {
            throw SSHKeyError.invalidFormat
        }
        guard key.publicKey == envelope.publicKey else { throw SSHKeyError.invalidFormat }
        return key
    }

    private static func unsupported(_ algorithm: String) -> SSHKeyError {
        if algorithm == "ssh-rsa" || algorithm.hasPrefix("rsa-") || algorithm.hasPrefix("ssh-rsa-") {
            return .rsaNotSupported
        }
        if algorithm.hasPrefix("sk-") { return .unsupportedKind("security key") }
        if algorithm == "ssh-dss" { return .unsupportedKind("DSA") }
        return .unsupportedKind(algorithm)
    }

    private static func envelope(_ text: String) throws -> Envelope {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("BEGIN RSA PRIVATE KEY") { throw SSHKeyError.rsaNotSupported }
        guard let start = trimmed.range(of: begin), let stop = trimmed.range(of: end),
              start.upperBound <= stop.lowerBound else { throw SSHKeyError.invalidFormat }
        let body = trimmed[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)), data.starts(with: magic) else {
            throw SSHKeyError.invalidFormat
        }
        var reader = SSHWireReader(data.dropFirst(magic.count))
        let cipher = try reader.readText()
        let kdf = try reader.readText()
        let kdfOptions = try reader.readString()
        let count = try reader.readUInt32()
        guard count == 1 else { throw count == 0 ? SSHKeyError.invalidFormat : SSHKeyError.multipleKeys }
        let publicBlob = try reader.readString()
        var publicReader = SSHWireReader(publicBlob)
        let algorithm = try publicReader.readText()
        // Known before any passphrase is asked for.
        guard SSHKeyKind(algorithm: algorithm) != nil else { throw unsupported(algorithm) }
        let encrypted = try reader.readString()
        return Envelope(
            cipher: cipher, kdf: kdf, kdfOptions: kdfOptions,
            publicKey: SSHPublicKey(algorithm: algorithm, blob: publicBlob),
            encrypted: encrypted, trailer: reader.readRest()
        )
    }

    // MARK: Decryption

    private static func decrypt(_ envelope: Envelope, passphrase: String) throws -> Data {
        let (keyLength, ivLength): (Int, Int) = switch envelope.cipher {
        case "aes128-ctr": (16, 16)
        case "aes192-ctr": (24, 16)
        case "aes256-ctr": (32, 16)
        case "aes256-gcm@openssh.com": (32, 12)
        default: throw SSHKeyError.unsupportedEncryption(envelope.cipher)
        }
        guard envelope.kdf == "bcrypt" else { throw SSHKeyError.unsupportedEncryption(envelope.kdf) }
        var options = SSHWireReader(envelope.kdfOptions)
        let salt = try options.readString()
        let rounds = Int(try options.readUInt32())
        guard rounds >= 1, rounds <= 1 << 16 else { throw SSHKeyError.invalidFormat }
        let derived = BcryptPBKDF.derive(
            password: Data(passphrase.utf8), salt: salt, rounds: rounds, length: keyLength + ivLength
        )
        let key = derived.prefix(keyLength), iv = derived.suffix(ivLength)

        if envelope.cipher == "aes256-gcm@openssh.com" {
            guard envelope.trailer.count >= 16 else { throw SSHKeyError.invalidFormat }
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: iv), ciphertext: envelope.encrypted, tag: envelope.trailer.prefix(16)
                )
                return try AES.GCM.open(box, using: SymmetricKey(data: key))
            } catch {
                throw SSHKeyError.wrongPassphrase
            }
        }
        return try aesCTR(envelope.encrypted, key: Data(key), iv: Data(iv))
    }

    private static func aesCTR(_ input: Data, key: Data, iv: Data) throws -> Data {
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE), &cryptor
                )
            }
        }
        guard created == kCCSuccess, let cryptor else { throw SSHKeyError.invalidFormat }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: input.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(
                    cryptor, inputBytes.baseAddress, input.count, outputBytes.baseAddress, input.count, &moved
                )
            }
        }
        guard status == kCCSuccess, moved == input.count else { throw SSHKeyError.invalidFormat }
        return output
    }

    // MARK: Legacy PEM

    /// An ECDSA key in the PEM files older `ssh-keygen` wrote, or a PKCS #8
    /// one. `nil` when the text is not PEM of that kind.
    private static func readLegacyPEM(
        _ text: String, passphrase: String?, checkOnly: Bool
    ) throws -> (isEncrypted: Bool, key: SSHPrivateKey?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") { throw SSHKeyError.rsaNotSupported }
        if trimmed.hasPrefix("-----BEGIN DSA PRIVATE KEY-----") { throw SSHKeyError.unsupportedKind("DSA") }
        let isEC = trimmed.hasPrefix("-----BEGIN EC PRIVATE KEY-----")
        let isPKCS8 = trimmed.hasPrefix("-----BEGIN PRIVATE KEY-----")
        if trimmed.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----") || (isEC && trimmed.contains("Proc-Type: 4,ENCRYPTED")) {
            if checkOnly { return (true, nil) }
            throw SSHKeyError.unsupportedEncryption("PEM encryption")
        }
        guard isEC || isPKCS8 else { return nil }
        if checkOnly { return (false, nil) }
        if isEC, let key = try sec1Key(trimmed) {
            return (false, key)
        }
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) {
            return (false, try SSHPrivateKey(kind: .ecdsaP256, rawRepresentation: key.rawRepresentation))
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) {
            return (false, try SSHPrivateKey(kind: .ecdsaP384, rawRepresentation: key.rawRepresentation))
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) {
            return (false, try SSHPrivateKey(kind: .ecdsaP521, rawRepresentation: key.rawRepresentation))
        }
        // A PKCS #8 file of an RSA key, most likely; nothing Twig can use.
        throw isPKCS8 ? SSHKeyError.rsaNotSupported : SSHKeyError.invalidFormat
    }

    /// SEC 1's ECPrivateKey, `SEQUENCE { INTEGER 1, OCTET STRING key, … }`.
    /// ssh-keygen writes the curve out in full rather than naming it, which
    /// CryptoKit does not read, so the scalar is taken out directly and the
    /// curve told by its length; the key's own check then confirms it.
    private static func sec1Key(_ pem: String) throws -> SSHPrivateKey? {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw SSHKeyError.invalidFormat }
        var bytes = [UInt8](der)[...]
        func element(_ tag: UInt8) throws -> ArraySlice<UInt8> {
            guard bytes.count >= 2, bytes.removeFirst() == tag else { throw SSHKeyError.invalidFormat }
            var length = Int(bytes.removeFirst())
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 3, bytes.count >= count else { throw SSHKeyError.invalidFormat }
                length = bytes.prefix(count).reduce(0) { $0 << 8 | Int($1) }
                bytes.removeFirst(count)
            }
            guard bytes.count >= length else { throw SSHKeyError.invalidFormat }
            defer { bytes.removeFirst(length) }
            return bytes.prefix(length)
        }
        bytes = try element(0x30)
        guard try element(0x02) == [1] else { throw SSHKeyError.invalidFormat }
        let scalar = Data(try element(0x04))
        let kind: SSHKeyKind
        switch scalar.count {
        case 32: kind = .ecdsaP256
        case 48: kind = .ecdsaP384
        case 66: kind = .ecdsaP521
        default: return nil
        }
        do {
            return try SSHPrivateKey(kind: kind, rawRepresentation: scalar)
        } catch {
            throw SSHKeyError.invalidFormat
        }
    }
}
