import Clibgit2

/// A SHA-1 object name.
public struct OID: Hashable, Sendable, CustomStringConvertible {
    // Twenty bytes held as three integers, so hashing and comparing the
    // hundreds of thousands of IDs in a history stay cheap.
    private let high: UInt64
    private let middle: UInt64
    private let low: UInt32

    init(_ oid: git_oid) {
        (high, middle, low) = withUnsafeBytes(of: oid.id) { bytes in
            (
                bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                bytes.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
            )
        }
    }

    init(_ pointer: UnsafePointer<git_oid>) {
        self.init(pointer.pointee)
    }

    /// Parses a full 40-character hexadecimal name.
    ///
    /// Done here rather than by libgit2 so that it works, and fails cleanly,
    /// before the library is initialized.
    public init?(hex: String) {
        var oid = git_oid()
        let parsed = withUnsafeMutableBytes(of: &oid.id) { bytes -> Bool in
            var index = 0
            var high: UInt8?
            for character in hex.utf8 {
                guard index < bytes.count, let value = Self.hexValue(of: character) else { return false }
                if let pending = high {
                    bytes[index] = pending << 4 | value
                    index += 1
                    high = nil
                } else {
                    high = value
                }
            }
            return index == bytes.count && high == nil
        }
        guard parsed else { return nil }
        self.init(oid)
    }

    private static func hexValue(of character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    var raw: git_oid {
        var oid = git_oid()
        withUnsafeMutableBytes(of: &oid.id) { bytes in
            bytes.storeBytes(of: high, toByteOffset: 0, as: UInt64.self)
            bytes.storeBytes(of: middle, toByteOffset: 8, as: UInt64.self)
            bytes.storeBytes(of: low, toByteOffset: 16, as: UInt32.self)
        }
        return oid
    }

    /// The full 40-character hexadecimal name.
    public var hex: String {
        withUnsafeBytes(of: raw.id) { bytes in
            String(unsafeUninitializedCapacity: 40) { buffer in
                let digits = Array("0123456789abcdef".utf8)
                for (index, byte) in bytes.enumerated() {
                    buffer[index * 2] = digits[Int(byte >> 4)]
                    buffer[index * 2 + 1] = digits[Int(byte & 0x0F)]
                }
                return 40
            }
        }
    }

    /// The first `length` characters of the name, as shown in lists.
    public func abbreviated(to length: Int = 8) -> String {
        String(hex.prefix(length))
    }

    public var description: String { hex }
}
