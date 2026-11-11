internal import Crypto
import Foundation

/// Blowfish, only as far as bcrypt's key schedule needs it.
///
/// Written for Twig from the published descriptions of Blowfish (Bruce
/// Schneier, 1993, placed in the public domain) and of bcrypt_pbkdf (OpenBSD,
/// which OpenSSH uses to protect private keys with a passphrase).
struct Blowfish {
    private var p: [UInt32]
    private var s0: [UInt32], s1: [UInt32], s2: [UInt32], s3: [UInt32]

    init() {
        p = Self.initialP
        s0 = Self.initialS[0]
        s1 = Self.initialS[1]
        s2 = Self.initialS[2]
        s3 = Self.initialS[3]
    }

    @inline(__always)
    private func f(_ x: UInt32) -> UInt32 {
        ((s0[Int(x >> 24)] &+ s1[Int((x >> 16) & 0xFF)]) ^ s2[Int((x >> 8) & 0xFF)]) &+ s3[Int(x & 0xFF)]
    }

    func encipher(_ left: inout UInt32, _ right: inout UInt32) {
        var l = left ^ p[0]
        var r = right
        var round = 1
        while round <= 16 {
            r ^= f(l) ^ p[round]
            l ^= f(r) ^ p[round + 1]
            round += 2
        }
        left = r ^ p[17]
        right = l
    }

    /// The next big-endian word of `data`, wrapping around at its end.
    private static func word(_ data: [UInt8], _ position: inout Int) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            if position >= data.count { position = 0 }
            value = value << 8 | UInt32(data[position])
            position += 1
        }
        return value
    }

    /// Eksblowfish's ExpandKey with a salt: `data` is mixed into each block.
    mutating func expand(data: [UInt8], key: [UInt8]) {
        var position = 0
        for index in 0..<18 {
            p[index] ^= Self.word(key, &position)
        }
        position = 0
        var left: UInt32 = 0, right: UInt32 = 0
        func next() {
            if !data.isEmpty {
                left ^= Self.word(data, &position)
                right ^= Self.word(data, &position)
            }
            encipher(&left, &right)
        }
        for index in stride(from: 0, to: 18, by: 2) {
            next()
            p[index] = left
            p[index + 1] = right
        }
        for box in 0..<4 {
            for index in stride(from: 0, to: 256, by: 2) {
                next()
                switch box {
                case 0: s0[index] = left; s0[index + 1] = right
                case 1: s1[index] = left; s1[index + 1] = right
                case 2: s2[index] = left; s2[index + 1] = right
                default: s3[index] = left; s3[index + 1] = right
                }
            }
        }
    }

    /// ExpandKey without a salt.
    mutating func expand(key: [UInt8]) {
        expand(data: [], key: key)
    }
}

/// bcrypt_pbkdf, the key derivation OpenSSH uses for passphrase-protected keys.
enum BcryptPBKDF {
    private static let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)

    /// bcrypt's core, over SHA-512 digests of the passphrase and salt.
    private static func hash(password: [UInt8], salt: [UInt8]) -> [UInt8] {
        var state = Blowfish()
        state.expand(data: salt, key: password)
        for _ in 0..<64 {
            state.expand(key: salt)
            state.expand(key: password)
        }
        var words = (0..<8).map { index in
            magic[index * 4..<index * 4 + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        for _ in 0..<64 {
            for block in stride(from: 0, to: 8, by: 2) {
                var left = words[block], right = words[block + 1]
                state.encipher(&left, &right)
                words[block] = left
                words[block + 1] = right
            }
        }
        // Little-endian out, unlike the rest of Blowfish.
        return words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } }
    }

    static func derive(password: Data, salt: Data, rounds: Int, length: Int) -> Data {
        precondition(rounds >= 1 && length > 0)
        let hashLength = 32
        let stride = (length + hashLength - 1) / hashLength
        let amount = (length + stride - 1) / stride
        let passwordDigest = Array(SHA512.hash(data: password))
        var key = [UInt8](repeating: 0, count: length)
        var remaining = length
        var count: UInt32 = 1
        while remaining > 0 {
            var countSalt = salt
            withUnsafeBytes(of: count.bigEndian) { countSalt.append(contentsOf: $0) }
            var output = hash(password: passwordDigest, salt: Array(SHA512.hash(data: countSalt)))
            var block = output
            for _ in 0..<rounds - 1 {
                block = hash(password: passwordDigest, salt: Array(SHA512.hash(data: Data(block))))
                for index in output.indices {
                    output[index] ^= block[index]
                }
            }
            // The output is spread across the key, not laid end to end.
            var copied = 0
            for index in 0..<min(amount, remaining) {
                let destination = index * stride + Int(count - 1)
                if destination >= length { break }
                key[destination] = output[index]
                copied += 1
            }
            remaining -= copied
            count += 1
        }
        return Data(key)
    }
}
