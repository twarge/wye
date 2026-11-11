import Foundation

/// Writes a zip archive to a file one entry at a time, so that a large
/// tree never has to be held in memory at once. Files are deflated with
/// the Compression framework when that makes them smaller, and stored as
/// they are otherwise. Entries carry Unix modes, so executable bits and
/// symbolic links survive `unzip`.
///
/// Only the classic format is written: an archive of more than 65,535
/// entries, or with a file or the archive itself over 4 GB, is refused
/// with ``ZipError/tooLarge`` rather than written in a form unzip cannot read.
public final class ZipWriter {
    private struct CentralEntry {
        var name: [UInt8]
        var method: UInt16
        var time: UInt16
        var date: UInt16
        var crc: UInt32
        var compressedSize: UInt32
        var size: UInt32
        var mode: UInt32
        var isDirectory: Bool
        var offset: UInt32
    }

    private let handle: FileHandle
    private var entries: [CentralEntry] = []
    private var offset: UInt64 = 0
    private var isFinished = false

    /// Creates the file at `url`, replacing one that is there.
    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    /// A folder, named with or without its trailing slash.
    public func addDirectory(_ path: String, date: Date, mode: UInt32 = 0o755) throws {
        let name = path.hasSuffix("/") ? path : path + "/"
        try add(name: name, data: Data(), mode: 0o040000 | (mode & 0o7777), date: date, isDirectory: true)
    }

    /// A regular file; `executable` gives it mode 755 rather than 644.
    public func addFile(_ path: String, data: Data, executable: Bool = false, date: Date) throws {
        try add(name: path, data: data, mode: 0o100000 | (executable ? 0o755 : 0o644), date: date, isDirectory: false)
    }

    /// A symbolic link whose contents are the path it points to, as zip
    /// stores links.
    public func addSymbolicLink(_ path: String, target: String, date: Date) throws {
        try add(name: path, data: Data(target.utf8), mode: 0o120777, date: date, isDirectory: false)
    }

    /// Writes the central directory and closes the file.
    public func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        guard entries.count <= Int(UInt16.max) else { throw ZipError.tooLarge }
        let start = offset
        for entry in entries {
            var record = ZipBytes()
            record.u32(0x0201_4b50)
            record.u16(3 << 8 | 20) // Made by Unix, zip 2.0.
            record.u16(20)
            record.u16(0x0800) // Names are UTF-8.
            record.u16(entry.method)
            record.u16(entry.time)
            record.u16(entry.date)
            record.u32(entry.crc)
            record.u32(entry.compressedSize)
            record.u32(entry.size)
            record.u16(UInt16(entry.name.count))
            record.u16(0) // Extra field.
            record.u16(0) // Comment.
            record.u16(0) // Disk.
            record.u16(0) // Internal attributes.
            record.u32(entry.mode << 16 | (entry.isDirectory ? 0x10 : 0))
            record.u32(entry.offset)
            record.bytes.append(contentsOf: entry.name)
            try write(record.bytes)
        }
        let size = offset - start
        guard offset <= UInt64(UInt32.max) else { throw ZipError.tooLarge }
        var end = ZipBytes()
        end.u32(0x0605_4b50)
        end.u16(0)
        end.u16(0)
        end.u16(UInt16(entries.count))
        end.u16(UInt16(entries.count))
        end.u32(UInt32(size))
        end.u32(UInt32(start))
        end.u16(0)
        try write(end.bytes)
        try handle.close()
    }

    // MARK: Writing

    private func add(name path: String, data: Data, mode: UInt32, date: Date, isDirectory: Bool) throws {
        precondition(!isFinished, "The archive is finished.")
        let name = Array(path.utf8)
        guard name.count <= Int(UInt16.max), data.count <= Int(UInt32.max), offset <= UInt64(UInt32.max) else {
            throw ZipError.tooLarge
        }
        let crc = CRC32.checksum(data)
        // Deflate only what it makes smaller; small and compressed files
        // are better stored.
        var method: UInt16 = 0
        var stored = data
        if data.count > 64, let deflated = try? (data as NSData).compressed(using: .zlib) as Data,
           deflated.count < data.count {
            method = 8
            stored = deflated
        }
        let (time, day) = Self.dosDateTime(date)
        let entry = CentralEntry(
            name: name, method: method, time: time, date: day, crc: crc,
            compressedSize: UInt32(stored.count), size: UInt32(data.count), mode: mode,
            isDirectory: isDirectory, offset: UInt32(offset)
        )
        var header = ZipBytes()
        header.u32(0x0403_4b50)
        header.u16(20)
        header.u16(0x0800)
        header.u16(method)
        header.u16(time)
        header.u16(day)
        header.u32(crc)
        header.u32(entry.compressedSize)
        header.u32(entry.size)
        header.u16(UInt16(name.count))
        header.u16(0)
        header.bytes.append(contentsOf: name)
        try write(header.bytes)
        try write(stored)
        entries.append(entry)
    }

    private func write(_ bytes: [UInt8]) throws {
        try write(Data(bytes))
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    /// MS-DOS time and date, in the local time zone as zip tools read
    /// them, clamped to the years DOS dates can hold.
    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = min(max((parts.year ?? 1980) - 1980, 0), 127)
        let time = (parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2
        let day = year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1)
        return (UInt16(time), UInt16(day))
    }
}

public enum ZipError: Error, Hashable, Sendable, LocalizedError {
    /// More than the classic zip format holds.
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .tooLarge:
            "The files are too many or too large for a zip archive: more than 65,535 files, or more than 4 GB."
        }
    }
}

/// Little-endian fields of a zip record.
private struct ZipBytes {
    var bytes: [UInt8] = []

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8(value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }
}

/// The CRC-32 zip records for each entry (the IEEE polynomial, reflected).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
