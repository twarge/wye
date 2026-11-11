import Clibgit2
import Foundation

/// Turns a libgit2 diff into values.
enum DiffBuilder {
    /// A file whose diff runs longer than this is cut short: nobody reads
    /// further, and laying it out would stall the interface.
    static let lineLimit = 5_000

    static func files(in diff: OpaquePointer?) throws -> [FileDiff] {
        let count = git_diff_num_deltas(diff)
        var files: [FileDiff] = []
        files.reserveCapacity(count)
        for index in 0..<count {
            var patch: OpaquePointer?
            try check(git_patch_from_diff(&patch, diff, index))
            defer { git_patch_free(patch) }
            // A binary or unchanged delta may come without a patch. The delta
            // is read after the patch because loading content settles whether
            // the file is binary.
            guard let delta = patch.map(git_patch_get_delta) ?? git_diff_get_delta(diff, index) else { continue }
            var file = FileDiff(delta.pointee)
            if let change = submoduleChange(delta.pointee) {
                // Its patch is only "Subproject commit" lines.
                file.submodule = change
                file.isBinary = false
            } else if let patch {
                try read(patch, into: &file)
            }
            files.append(file)
        }
        return files
    }

    /// The recorded commits, when either side of a delta is a submodule.
    private static func submoduleChange(_ delta: git_diff_delta) -> SubmoduleChange? {
        let commit = UInt16(GIT_FILEMODE_COMMIT.rawValue)
        guard delta.old_file.mode == commit || delta.new_file.mode == commit else { return nil }
        func id(_ file: git_diff_file) -> OID? {
            let id = OID(file.id)
            return file.mode == commit && id != RemoteSession.noObject ? id : nil
        }
        return SubmoduleChange(oldID: id(delta.old_file), newID: id(delta.new_file))
    }

    private static func read(_ patch: OpaquePointer, into file: inout FileDiff) throws {
        var context = 0, additions = 0, deletions = 0
        try check(git_patch_line_stats(&context, &additions, &deletions, patch))
        file.additions = additions
        file.deletions = deletions

        var lineID = 0
        for hunkIndex in 0..<git_patch_num_hunks(patch) {
            var hunkPointer: UnsafePointer<git_diff_hunk>?
            var lineCount = 0
            try check(git_patch_get_hunk(&hunkPointer, &lineCount, patch, hunkIndex))
            guard let hunkPointer else { continue }

            var hunk = FileDiff.Hunk(id: hunkIndex, header: header(of: hunkPointer.pointee), lines: [])
            hunk.lines.reserveCapacity(lineCount)
            for lineIndex in 0..<lineCount {
                guard lineID < lineLimit else {
                    file.isTruncated = true
                    break
                }
                var linePointer: UnsafePointer<git_diff_line>?
                try check(git_patch_get_line_in_hunk(&linePointer, patch, hunkIndex, lineIndex))
                guard let line = linePointer?.pointee, let kind = FileDiff.Line.Kind(origin: line.origin) else {
                    continue
                }
                hunk.lines.append(FileDiff.Line(
                    id: lineID,
                    kind: kind,
                    oldNumber: line.old_lineno > 0 ? Int(line.old_lineno) : nil,
                    newNumber: line.new_lineno > 0 ? Int(line.new_lineno) : nil,
                    text: kind == .noNewline ? "No newline at end of file" : text(of: line)
                ))
                lineID += 1
            }
            file.hunks.append(hunk)
            if file.isTruncated { break }
        }
    }

    private static func header(of hunk: git_diff_hunk) -> String {
        withUnsafeBytes(of: hunk.header) { bytes in
            String(decoding: bytes.prefix(hunk.header_len), as: UTF8.self)
        }
        .trimmingCharacters(in: .newlines)
    }

    private static func text(of line: git_diff_line) -> String {
        var bytes = UnsafeRawBufferPointer(start: line.content, count: line.content_len)[...]
        if bytes.last == UInt8(ascii: "\n") { bytes = bytes.dropLast() }
        if bytes.last == UInt8(ascii: "\r") { bytes = bytes.dropLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension FileDiff {
    init(_ delta: git_diff_delta) {
        let newPath = delta.new_file.path.map { String(cString: $0) }
        let oldPath = delta.old_file.path.map { String(cString: $0) }
        self.init(
            change: FileChange(delta.status) ?? .modified,
            oldPath: oldPath ?? newPath ?? "",
            path: newPath ?? oldPath ?? "",
            isBinary: delta.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0,
            additions: 0,
            deletions: 0,
            hunks: [],
            isTruncated: false
        )
    }
}

extension FileChange {
    init?(_ status: git_delta_t) {
        switch status {
        case GIT_DELTA_ADDED: self = .added
        case GIT_DELTA_DELETED: self = .deleted
        case GIT_DELTA_MODIFIED: self = .modified
        case GIT_DELTA_RENAMED: self = .renamed
        case GIT_DELTA_COPIED: self = .copied
        case GIT_DELTA_TYPECHANGE: self = .typeChanged
        case GIT_DELTA_UNTRACKED: self = .untracked
        case GIT_DELTA_CONFLICTED: self = .conflicted
        default: return nil
        }
    }
}

extension FileDiff.Line.Kind {
    init?(origin: CChar) {
        switch UInt8(bitPattern: origin) {
        case UInt8(ascii: " "): self = .context
        case UInt8(ascii: "+"): self = .addition
        case UInt8(ascii: "-"): self = .deletion
        case UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "<"): self = .noNewline
        default: return nil
        }
    }
}

/// Calls `body` with `strings` as a libgit2 string array.
func withStringArray<Result>(
    _ strings: [String], _ body: (inout git_strarray) throws -> Result
) rethrows -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        var array = git_strarray(strings: buffer.baseAddress, count: buffer.count)
        return try body(&array)
    }
}
