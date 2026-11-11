import Clibgit2
import Foundation

/// The bytes on each side of a changed file, for showing what a binary file
/// such as an image looked like before and after.
public struct DiffSides: Hashable, Sendable {
    /// One side's bytes.
    public struct Side: Hashable, Sendable {
        /// The size in bytes.
        public var size: Int
        /// The bytes; `nil` when the file is larger than the limit asked for,
        /// so it was measured but not read.
        public var data: Data?

        public init(size: Int, data: Data?) {
            self.size = size
            self.data = data
        }
    }

    /// The file before the change; `nil` where it did not exist.
    public var old: Side?
    /// The file after the change; `nil` where it no longer exists.
    public var new: Side?

    public init(old: Side?, new: Side?) {
        self.old = old
        self.new = new
    }
}

extension Repository {
    /// Reads both sides of a file's diff: blobs from the object database, and
    /// for a diff whose new side is the working tree, the file on disk. A side
    /// larger than `limit` bytes is measured but not read.
    public func sides(of file: FileDiff, limit: Int = 32 << 20) throws -> DiffSides {
        let hasOld = file.change != .added && file.change != .untracked
        let hasNew = file.change != .deleted
        let old = hasOld ? try file.oldBlobID.flatMap { try blobSide($0, limit: limit) } : nil
        var new: DiffSides.Side?
        if hasNew {
            if file.newSideIsWorkingTree {
                new = try workingTreeSide(file.path, limit: limit)
            } else if let id = file.newBlobID {
                new = try blobSide(id, limit: limit)
            }
        }
        return DiffSides(old: old, new: new)
    }

    /// A blob's size and, within the limit, its bytes; `nil` when the
    /// object database does not have it.
    private func blobSide(_ id: OID, limit: Int) throws -> DiffSides.Side? {
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, pointer))
        defer { git_odb_free(odb) }
        var oid = id.raw
        var size = 0
        var type = GIT_OBJECT_INVALID
        guard git_odb_read_header(&size, &type, odb, &oid) == 0, type == GIT_OBJECT_BLOB else { return nil }
        guard size <= limit else { return DiffSides.Side(size: size, data: nil) }
        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, pointer, &oid))
        defer { git_blob_free(blob) }
        let data = Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
        return DiffSides.Side(size: data.count, data: data)
    }

    /// A working tree file's size and, within the limit, its bytes; `nil`
    /// when there is no file there.
    private func workingTreeSide(_ path: String, limit: Int) throws -> DiffSides.Side? {
        guard let root = git_repository_workdir(pointer) else { return nil }
        let url = URL(filePath: String(cString: root), directoryHint: .isDirectory)
            .appending(path: path, directoryHint: .notDirectory)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        guard size <= limit else { return DiffSides.Side(size: size, data: nil) }
        let data = try Data(contentsOf: url)
        return DiffSides.Side(size: data.count, data: data)
    }
}
