import Foundation

/// Reads the SSH wire format (RFC 4251 §5): big-endian integers and
/// length-prefixed strings, as key files and key blobs are written in.
struct SSHWireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        offset = 0
    }

    var isAtEnd: Bool { offset >= data.count }
    var remaining: Int { data.count - offset }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SSHKeyError.invalidFormat }
        let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw SSHKeyError.invalidFormat }
        let bytes = data[offset..<offset + count]
        offset += count
        return Data(bytes)
    }

    mutating func readString() throws -> Data {
        try readBytes(Int(try readUInt32()))
    }

    mutating func readText() throws -> String {
        guard let text = String(data: try readString(), encoding: .utf8) else { throw SSHKeyError.invalidFormat }
        return text
    }

    /// An `mpint` as an unsigned big-endian number, without the sign byte.
    mutating func readUnsignedMPInt() throws -> Data {
        var bytes = try readString()
        while let first = bytes.first, first == 0 {
            bytes.removeFirst()
        }
        return bytes
    }

    mutating func readRest() -> Data {
        defer { offset = data.count }
        return Data(data[offset...])
    }
}

/// Writes the SSH wire format.
struct SSHWireWriter {
    private(set) var data = Data()

    mutating func write(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(string: Data) {
        write(UInt32(string.count))
        data.append(string)
    }

    mutating func write(string: String) {
        write(string: Data(string.utf8))
    }
}
