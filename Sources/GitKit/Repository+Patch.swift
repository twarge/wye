import Clibgit2
import Foundation

/// Which of the working copy's two diffs a change is taken from.
public enum WorkingCopySide: Hashable, Sendable {
    /// Between `HEAD` and the index.
    case staged
    /// Between the index and the working tree.
    case unstaged
}

/// What to do with an untracked file whose changes are discarded.
public enum UntrackedRemoval: Hashable, Sendable {
    /// Move it to the Trash where the volume has one, and delete it otherwise.
    case trash
    case delete
}

extension FileDiff.Hunk {
    /// The lines this hunk adds or removes: what staging the whole hunk selects.
    public var changedLineIDs: Set<Int> {
        Set(lines.lazy.filter(\.isChange).map(\.id))
    }
}

extension FileDiff {
    public var changedLineIDs: Set<Int> {
        hunks.reduce(into: []) { $0.formUnion($1.changedLineIDs) }
    }
}

extension FileDiff.Line {
    /// Whether the line adds or removes something, so can be staged on its own.
    public var isChange: Bool {
        kind == .addition || kind == .deletion
    }
}

extension Repository {
    /// Stages some of a file's unstaged lines, given by their IDs in `file`,
    /// its unstaged diff as last read.
    public func stage(lines: Set<Int>, of file: FileDiff) throws {
        try apply(lines, of: file, side: .unstaged, reversed: false, location: GIT_APPLY_LOCATION_INDEX) {
            try stage([file.path])
        }
    }

    /// Unstages some of a file's staged lines, given by their IDs in `file`,
    /// its staged diff as last read.
    public func unstage(lines: Set<Int>, of file: FileDiff) throws {
        try apply(lines, of: file, side: .staged, reversed: true, location: GIT_APPLY_LOCATION_INDEX) {
            try unstage([file.path])
        }
    }

    /// Throws away some of a file's unstaged lines in the working tree, given
    /// by their IDs in `file`, its unstaged diff as last read.
    public func discard(lines: Set<Int>, of file: FileDiff, untracked: UntrackedRemoval = .trash) throws {
        try apply(lines, of: file, side: .unstaged, reversed: true, location: GIT_APPLY_LOCATION_WORKDIR) {
            try discardChanges(in: [file.path], untracked: untracked)
        }
    }

    /// Builds a patch for the selected lines and applies it.
    ///
    /// - Parameters:
    ///   - reversed: Whether the patch undoes the selection instead, as
    ///     unstaging and discarding do.
    ///   - wholeFile: What to do instead when every change is selected, which
    ///     also takes care of whatever a patch cannot carry, such as a new
    ///     file's existence or a change of mode.
    private func apply(
        _ ids: Set<Int>, of file: FileDiff, side: WorkingCopySide, reversed: Bool,
        location: git_apply_location_t, wholeFile: () throws -> Void
    ) throws {
        let source = try patchSource(of: file, side: side)
        let changed = source.changedLineIDs
        let selected = ids.intersection(changed)
        guard !selected.isEmpty else { throw WorkingCopyError.nothingSelected }
        if selected == changed {
            return try wholeFile()
        }
        guard let patch = PatchBuilder.patch(for: source, selecting: selected, reversed: reversed) else {
            throw WorkingCopyError.nothingSelected
        }
        try apply(patch: patch, location: location)
    }

    private func apply(patch: [UInt8], location: git_apply_location_t) throws {
        var diff: OpaquePointer?
        try patch.withUnsafeBufferPointer { bytes in
            try bytes.withMemoryRebound(to: CChar.self) { text in
                _ = try check(git_diff_from_buffer(&diff, text.baseAddress, text.count))
            }
        }
        defer { git_diff_free(diff) }
        try check(git_apply(pointer, diff, location, nil))
    }

    /// Reads a file's diff again with every line's exact bytes, which the
    /// shown diff does not keep, and checks it is still the diff that was shown.
    private func patchSource(of shown: FileDiff, side: WorkingCopySide) throws -> PatchSource {
        try withWorkingCopyDiff(of: shown.path, side: side) { diff in
            guard git_diff_num_deltas(diff) == 1, try DiffBuilder.files(in: diff).first == shown else {
                throw WorkingCopyError.diffChanged(path: shown.path)
            }
            var patch: OpaquePointer?
            try check(git_patch_from_diff(&patch, diff, 0))
            defer { git_patch_free(patch) }
            guard let patch, let delta = git_patch_get_delta(patch)?.pointee else {
                throw WorkingCopyError.diffChanged(path: shown.path)
            }
            return try PatchSource(patch, delta: delta)
        }
    }

    /// Calls `body` with one file's staged or unstaged diff, read with the
    /// same options as `stagedDiff(of:)` and `unstagedDiff(of:)`.
    func withWorkingCopyDiff<Result>(
        of path: String, side: WorkingCopySide, _ body: (OpaquePointer?) throws -> Result
    ) throws -> Result {
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags = GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
        if side == .unstaged {
            options.flags |= GIT_DIFF_INCLUDE_UNTRACKED.rawValue
                | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
                | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue
        }
        return try withStringArray([path]) { paths in
            options.pathspec = paths
            var diff: OpaquePointer?
            switch side {
            case .staged:
                let head = try headCommit()
                defer { git_commit_free(head) }
                let headTree = try tree(of: head)
                defer { git_tree_free(headTree) }
                try check(git_diff_tree_to_index(&diff, pointer, headTree, nil, &options))
            case .unstaged:
                try check(git_diff_index_to_workdir(&diff, pointer, nil, &options))
            }
            defer { git_diff_free(diff) }
            return try body(diff)
        }
    }
}

/// One file's diff with each line's exact bytes, from which a patch is made.
struct PatchSource {
    var oldPath: String
    var newPath: String
    /// `0` on the side where the file does not exist.
    var oldMode: UInt32
    var newMode: UInt32
    var hunks: [Hunk]

    struct Hunk {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var lines: [Line]
    }

    struct Line {
        /// The same ID the line has in the `FileDiff` read from the same diff.
        var id: Int
        var kind: FileDiff.Line.Kind
        /// The line's content, ending in a newline unless it is the last line
        /// of a file that does not end in one.
        var bytes: [UInt8]
    }

    var changedLineIDs: Set<Int> {
        Set(hunks.flatMap(\.lines).lazy.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
    }

    /// Reads the lines as `DiffBuilder` does, numbering them the same way,
    /// but without its limit on length.
    init(_ patch: OpaquePointer, delta: git_diff_delta) throws {
        let newPath = delta.new_file.path.map { String(cString: $0) }
        let oldPath = delta.old_file.path.map { String(cString: $0) }
        self.oldPath = oldPath ?? newPath ?? ""
        self.newPath = newPath ?? oldPath ?? ""
        oldMode = delta.status == GIT_DELTA_ADDED || delta.status == GIT_DELTA_UNTRACKED ? 0 : UInt32(delta.old_file.mode)
        newMode = delta.status == GIT_DELTA_DELETED ? 0 : UInt32(delta.new_file.mode)
        hunks = []

        var lineID = 0
        for hunkIndex in 0..<git_patch_num_hunks(patch) {
            var hunkPointer: UnsafePointer<git_diff_hunk>?
            var lineCount = 0
            try check(git_patch_get_hunk(&hunkPointer, &lineCount, patch, hunkIndex))
            guard let header = hunkPointer?.pointee else { continue }
            var hunk = Hunk(
                oldStart: Int(header.old_start), oldCount: Int(header.old_lines),
                newStart: Int(header.new_start), newCount: Int(header.new_lines), lines: []
            )
            for lineIndex in 0..<lineCount {
                var linePointer: UnsafePointer<git_diff_line>?
                try check(git_patch_get_line_in_hunk(&linePointer, patch, hunkIndex, lineIndex))
                guard let line = linePointer?.pointee, let kind = FileDiff.Line.Kind(origin: line.origin) else {
                    continue
                }
                let bytes = line.content.map {
                    Array(UnsafeRawBufferPointer(start: $0, count: line.content_len))
                } ?? []
                hunk.lines.append(Line(id: lineID, kind: kind, bytes: bytes))
                lineID += 1
            }
            hunks.append(hunk)
        }
    }
}

/// Writes the patch for part of a diff.
enum PatchBuilder {
    private static let newline = UInt8(ascii: "\n")
    private static let context = UInt8(ascii: " ")
    private static let deletion = UInt8(ascii: "-")
    private static let addition = UInt8(ascii: "+")

    private struct Line {
        var origin: UInt8
        var bytes: [UInt8]

        var isOld: Bool { origin != PatchBuilder.addition }
        var isNew: Bool { origin != PatchBuilder.deletion }
        var endsLine: Bool { bytes.last == PatchBuilder.newline }
    }

    /// A unified patch that makes only the selected changes, or with
    /// `reversed`, undoes only them. `nil` when nothing is selected.
    ///
    /// The patch applies to the side being changed: the diff's old side, or
    /// its new side when reversed. Every line of that side stays in the
    /// patch, so it still matches what it applies to: an unselected removal
    /// becomes context, while an unselected addition is left out.
    static func patch(for source: PatchSource, selecting ids: Set<Int>, reversed: Bool) -> [UInt8]? {
        var body: [UInt8] = []
        // How far the hunks written so far moved the lines after them.
        var offset = 0
        for hunk in source.hunks {
            var lines: [Line] = []
            var selectsSomething = false
            for line in hunk.lines {
                let isSelected = ids.contains(line.id)
                switch (line.kind, reversed) {
                case (.context, _):
                    lines.append(Line(origin: context, bytes: line.bytes))
                case (.deletion, false), (.addition, true):
                    lines.append(Line(origin: isSelected ? deletion : context, bytes: line.bytes))
                    selectsSomething = selectsSomething || isSelected
                case (.addition, false), (.deletion, true):
                    if isSelected {
                        lines.append(Line(origin: addition, bytes: line.bytes))
                        selectsSomething = true
                    }
                case (.noNewline, _):
                    // Written again below for whichever lines still need it.
                    break
                }
            }
            guard selectsSomething else { continue }
            lines = removalsFirst(endingLines(lines))

            let oldStart = reversed ? hunk.newStart : hunk.oldStart
            let oldCount = lines.count(where: \.isOld)
            let newCount = lines.count(where: \.isNew)
            // As git writes them: an empty side starts at the line before.
            var newStart = oldStart + offset
            if oldCount == 0 {
                newStart += 1
            } else if newCount == 0 {
                newStart -= 1
            }
            offset += newCount - oldCount

            body += Array("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n".utf8)
            for line in lines {
                body.append(line.origin)
                body += line.bytes
                if !line.endsLine {
                    body += Array("\n\\ No newline at end of file\n".utf8)
                }
            }
        }
        guard !body.isEmpty else { return nil }
        return header(for: source, reversed: reversed) + body
    }

    /// Only the last line of a file can go without a newline. Leaving out an
    /// addition can put such a line before others on the new side; there it
    /// gets the newline it has to have.
    private static func endingLines(_ lines: [Line]) -> [Line] {
        guard let last = lines.lastIndex(where: \.isNew) else { return lines }
        var result: [Line] = []
        result.reserveCapacity(lines.count + 1)
        for (index, line) in lines.enumerated() {
            guard index < last, line.isNew, !line.endsLine else {
                result.append(line)
                continue
            }
            if line.origin == context {
                // The old side keeps it as it is; the new side gains the newline.
                result.append(Line(origin: deletion, bytes: line.bytes))
            }
            result.append(Line(origin: addition, bytes: line.bytes + [newline]))
        }
        return result
    }

    /// Puts each run of changes in the order git writes them, removals then
    /// additions, so a "no newline" marker after a removal comes where a
    /// parser looks for it. Each side keeps its own order.
    private static func removalsFirst(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        result.reserveCapacity(lines.count)
        var additions: [Line] = []
        for line in lines {
            switch line.origin {
            case deletion:
                result.append(line)
            case addition:
                additions.append(line)
            default:
                result += additions
                additions.removeAll(keepingCapacity: true)
                result.append(line)
            }
        }
        return result + additions
    }

    private static func header(for source: PatchSource, reversed: Bool) -> [UInt8] {
        let old = "a/" + source.oldPath
        let new = "b/" + source.newPath
        // The side being patched, whose mode is kept: staging some lines
        // does not stage a change of mode.
        let (patchedMode, otherMode) = reversed ? (source.newMode, source.oldMode) : (source.oldMode, source.newMode)
        var text = "diff --git \(quoted(old)) \(quoted(new))\n"
        if patchedMode == 0 {
            text += "new file mode \(String(otherMode, radix: 8))\n"
            text += "--- /dev/null\n"
        } else {
            text += "index 0000000..0000000 \(String(patchedMode, radix: 8))\n"
            text += "--- \(quoted(old))\n"
        }
        text += "+++ \(quoted(new))\n"
        return Array(text.utf8)
    }

    /// A path in git's quoted form, which leaves no doubt where it ends.
    private static func quoted(_ path: String) -> String {
        var result = "\""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                let octal = String(scalar.value, radix: 8)
                result += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
