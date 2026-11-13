import Clibgit2
import Foundation

extension Repository {
    /// Files larger than this are not searched, as most of them are data
    /// rather than text anyone types.
    static let largestSearchedFile = 2 << 20

    /// Whether a commit added or removed a line holding the matcher's text,
    /// compared with its parent, as `git log -G` finds them for a plain
    /// string, but ignoring case.
    ///
    /// As there, merges are passed over: what they bring in is listed
    /// already, as the commits that made it. Following first parents only,
    /// where a merge stands for its branch, a merge is compared with its
    /// first parent instead. Binary files, submodules and files over
    /// `largestSearchedFile` are skipped, and a file moved unchanged is no
    /// change to its lines.
    func changesContent(_ matcher: ContentMatcher, in commit: OpaquePointer, walk: Walk) throws -> Bool {
        let parentCount = git_commit_parentcount(commit)
        guard parentCount <= 1 || walk.firstParentOnly else { return false }
        let tree = try self.tree(of: commit)
        defer { git_tree_free(tree) }
        var parent: OpaquePointer?
        if parentCount > 0 {
            try check(git_commit_parent(&parent, commit, 0))
        }
        defer { git_commit_free(parent) }
        let parentTree = try self.tree(of: parent)
        defer { git_tree_free(parentTree) }
        return try changesContent(matcher, from: parentTree, to: tree, walk: walk)
    }

    private func changesContent(
        _ matcher: ContentMatcher, from oldTree: OpaquePointer?, to newTree: OpaquePointer?, walk: Walk
    ) throws -> Bool {
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags |= GIT_DIFF_IGNORE_SUBMODULES.rawValue
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, pointer, oldTree, newTree, &options))
        defer { git_diff_free(diff) }
        // Pairs a file moved unchanged by its blob, without reading it.
        var find = git_diff_find_options()
        try check(git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)))
        find.flags = GIT_DIFF_FIND_RENAMES.rawValue | GIT_DIFF_FIND_EXACT_MATCH_ONLY.rawValue
        try check(git_diff_find_similar(diff, &find))
        for index in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, index)?.pointee else { continue }
            if try changesContent(matcher, delta, walk: walk) { return true }
        }
        return false
    }

    /// Whether one file's change added or removed a line holding the text.
    private func changesContent(_ matcher: ContentMatcher, _ delta: git_diff_delta, walk: Walk) throws -> Bool {
        var oldID = delta.old_file.id
        var newID = delta.new_file.id
        guard git_oid_equal(&oldID, &newID) == 0,
              UInt32(delta.old_file.mode) != GIT_FILEMODE_COMMIT.rawValue,
              UInt32(delta.new_file.mode) != GIT_FILEMODE_COMMIT.rawValue else { return false }

        // Lines left as they were hold the text as often before as after,
        // so a difference in the count is a line added or removed.
        guard let before = count(matcher, in: oldID, walk: walk),
              let after = count(matcher, in: newID, walk: walk) else { return false }
        if before != after { return true }
        if before == 0 { return false }

        // As often before as after: a line holding it may still have been
        // rewritten, or one moved. The diff's lines tell.
        guard let old = SearchedBlob(oldID, in: pointer) else { return false }
        defer { old.free() }
        guard let new = SearchedBlob(newID, in: pointer) else { return false }
        defer { new.free() }
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.context_lines = 0
        options.interhunk_lines = 0
        var patch: OpaquePointer?
        try check(git_patch_from_blobs(&patch, old.blob, nil, new.blob, nil, &options))
        defer { git_patch_free(patch) }
        let added = CChar(GIT_DIFF_LINE_ADDITION.rawValue)
        let removed = CChar(GIT_DIFF_LINE_DELETION.rawValue)
        for hunk in 0..<git_patch_num_hunks(patch) {
            let count = Int(git_patch_num_lines_in_hunk(patch, hunk))
            guard count > 0 else { continue }
            for index in 0..<count {
                var line: UnsafePointer<git_diff_line>?
                try check(git_patch_get_line_in_hunk(&line, patch, hunk, index))
                guard let line = line?.pointee, line.origin == added || line.origin == removed else { continue }
                let bytes = UnsafeRawBufferPointer(start: line.content, count: line.content_len)
                if matcher.count(in: bytes, upTo: 1) > 0 { return true }
            }
        }
        return false
    }
}

extension Repository {
    /// How often the text occurs in a blob, from the walk's counts when it
    /// has been read before; `nil` for one not searched.
    fileprivate func count(_ matcher: ContentMatcher, in id: git_oid, walk: Walk) -> Int? {
        var id = id
        guard git_oid_is_zero(&id) == 0 else { return 0 }
        let key = OID(id)
        if let known = walk.contentCounts[key] { return known }
        let count = SearchedBlob(id, in: pointer).map { blob in
            defer { blob.free() }
            return matcher.count(in: blob.bytes)
        }
        walk.contentCounts[key] = count
        return count
    }
}

/// One side of a file's change, as searched: its bytes, or none for a file
/// that was added or deleted.
private struct SearchedBlob {
    let blob: OpaquePointer?
    let bytes: UnsafeRawBufferPointer

    /// `nil` for a blob that is not searched: binary, too large, or not in
    /// this clone.
    init?(_ id: git_oid, in repository: OpaquePointer) {
        var id = id
        guard git_oid_is_zero(&id) == 0 else {
            blob = nil
            bytes = UnsafeRawBufferPointer(start: nil, count: 0)
            return
        }
        var blob: OpaquePointer?
        guard git_blob_lookup(&blob, repository, &id) == 0 else { return nil }
        let size = Int(git_blob_rawsize(blob))
        guard size <= Repository.largestSearchedFile, git_blob_is_binary(blob) == 0 else {
            git_blob_free(blob)
            return nil
        }
        self.blob = blob
        bytes = UnsafeRawBufferPointer(start: git_blob_rawcontent(blob), count: size)
    }

    func free() {
        git_blob_free(blob)
    }
}

/// Finds a search's text in a file's bytes, ignoring case. Text in ASCII,
/// as code mostly is, is found byte by byte: `memchr` jumps to each place
/// one of its bytes could be, preferring one that is not a letter and so
/// has no other case, and the rest is compared there. Other text goes
/// through `String`, which is slower.
struct ContentMatcher: Sendable {
    /// The text in lower case, when it is all ASCII.
    private let folded: [UInt8]?
    private let text: String
    /// Where in the text the byte `memchr` looks for is, and that byte in
    /// each case it has.
    private let anchor: Int
    private let anchorBytes: [UInt8]

    init(_ text: String) {
        self.text = text
        guard text.utf8.allSatisfy({ $0 < 0x80 }), !text.isEmpty else {
            folded = nil
            anchor = 0
            anchorBytes = []
            return
        }
        let folded = Array(text.lowercased().utf8)
        self.folded = folded
        let isLetter: (UInt8) -> Bool = { $0 >= 0x61 && $0 <= 0x7A }
        anchor = folded.firstIndex { !isLetter($0) } ?? 0
        let byte = folded[anchor]
        anchorBytes = isLetter(byte) ? [byte, byte - 0x20] : [byte]
    }

    /// How many times the text occurs, without overlapping, counting no
    /// further than `limit`.
    func count(in bytes: UnsafeRawBufferPointer, upTo limit: Int = .max) -> Int {
        guard !text.isEmpty, let base = bytes.baseAddress, bytes.count > 0 else { return 0 }
        guard let folded else {
            let string = String(decoding: bytes, as: UTF8.self)
            var count = 0
            var rest = string.startIndex..<string.endIndex
            while count < limit, let found = string.range(of: text, options: .caseInsensitive, range: rest) {
                count += 1
                rest = found.upperBound..<string.endIndex
            }
            return count
        }
        let length = folded.count
        let size = bytes.count
        guard size >= length else { return 0 }
        let start = base.assumingMemoryBound(to: UInt8.self)
        return folded.withUnsafeBufferPointer { term in
            /// Whether the text starts at `offset`.
            func matches(at offset: Int) -> Bool {
                for index in 0..<length where Self.fold(start[offset + index]) != term[index] {
                    return false
                }
                return true
            }
            /// The next place at or after `offset` that `byte` is, or `size`.
            func next(_ byte: UInt8, from offset: Int) -> Int {
                guard offset < size, let found = memchr(start + offset, Int32(byte), size - offset) else { return size }
                return UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - start
            }
            var count = 0
            // The first place the text could start that is still to be tried.
            var from = 0
            var upcoming = anchorBytes.map { next($0, from: anchor) }
            while true {
                let position = upcoming.min()!
                guard position < size else { return count }
                let offset = position - anchor
                if offset >= from, offset + length <= size, matches(at: offset) {
                    count += 1
                    if count >= limit { return count }
                    from = offset + length
                }
                let resume = max(position + 1, from + anchor)
                for index in upcoming.indices where upcoming[index] < resume {
                    upcoming[index] = next(anchorBytes[index], from: resume)
                }
            }
        }
    }

    @inline(__always)
    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
    }
}
