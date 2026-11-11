import Clibgit2
import Foundation

/// A conflicted file, read from the index's three stages, ready to resolve.
public struct ConflictFile: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// Text both sides changed, to merge line by line.
        case text(MergeText)
        /// Not text that can be merged by line: binary data, text that is not
        /// UTF-8, a symbolic link or a submodule. One side is taken whole.
        case whole
        /// One side changed the file and the other deleted it: keep it or delete it.
        case deleted(by: ConflictSide)
        /// Both sides took the file away, as when each renamed it differently.
        case deletedOnBothSides
    }

    public let path: String
    public let content: Content
    /// Whether the common ancestor had the file. Without one, as when both
    /// sides added it, each side's lines all count as changes.
    public let hasBase: Bool
    /// What each side is, for labelling them.
    public let labels: ConflictLabels
    /// The three stages' objects as they were read, to notice the conflict
    /// changing before a resolution is saved.
    let stages: [OID?]
}

/// What the two sides of a conflict are, as the operation under way has them.
public struct ConflictLabels: Hashable, Sendable {
    public let operation: OngoingOperation.Kind?
    /// The index's "ours", stage 2: always what `HEAD` was.
    public let ours: ConflictSideLabel
    /// The index's "theirs", stage 3.
    public let theirs: ConflictSideLabel
}

public struct ConflictSideLabel: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        /// The branch being merged into, or that a commit is applied to.
        case current
        /// What a merge brings in.
        case incoming
        /// During a rebase, `HEAD` is the branch being rebased onto, with
        /// the commits replayed so far: git's "ours" is not your branch.
        case onto
        /// During a rebase, your commit being replayed: git's "theirs".
        case replayed
        /// The commit a cherry-pick is applying.
        case picked
        /// The commit a revert is undoing; its side is the commit's parent.
        case reverted
    }

    public let role: Role
    /// A branch or tag's short name, when one is known.
    public let name: String?
    public let commit: OID?
    public let summary: String?

    public init(role: Role, name: String?, commit: OID?, summary: String?) {
        self.role = role
        self.name = name
        self.commit = commit
        self.summary = summary
    }
}

/// Why a resolution could not be saved.
public enum ConflictError: Error, Hashable, Sendable, LocalizedError {
    /// The conflict was resolved, or changed, since the file was read.
    case changed(path: String)
    case notText(path: String)

    public var errorDescription: String? {
        switch self {
        case .changed(let path):
            "The conflict in “\(path)” changed since it was opened. Open it again to resolve it."
        case .notText(let path):
            "“\(path)” cannot be merged line by line. Use one side’s version instead."
        }
    }
}

extension Repository {
    /// Reads a conflicted file's three versions from the index and merges
    /// them as git does, with the diff3 style, into merged lines and conflicts.
    public func conflictFile(at path: String) throws -> ConflictFile {
        let index = try branchingIndex()
        defer { git_index_free(index) }
        var ancestor: UnsafePointer<git_index_entry>?
        var ours: UnsafePointer<git_index_entry>?
        var theirs: UnsafePointer<git_index_entry>?
        let code = git_index_conflict_get(&ancestor, &ours, &theirs, index, path)
        if code == GIT_ENOTFOUND.rawValue { throw WorkingCopyError.notConflicted(path: path) }
        try check(code)

        let stages = [ancestor, ours, theirs].map { $0.map { OID($0.pointee.id) } }
        let labels = try conflictLabels()
        func file(_ content: ConflictFile.Content) -> ConflictFile {
            ConflictFile(path: path, content: content, hasBase: ancestor != nil, labels: labels, stages: stages)
        }

        switch (ours, theirs) {
        case (nil, nil): return file(.deletedOnBothSides)
        case (nil, _): return file(.deleted(by: .ours))
        case (_, nil): return file(.deleted(by: .theirs))
        default: break
        }
        guard let ours, let theirs, [ours, theirs].allSatisfy({ Self.isRegularFile($0.pointee.mode) }) else {
            return file(.whole)
        }
        guard let ourText = try textOfBlob(ours), let theirText = try textOfBlob(theirs) else {
            return file(.whole)
        }
        var baseText: [UInt8] = []
        if let ancestor, Self.isRegularFile(ancestor.pointee.mode) {
            guard let text = try textOfBlob(ancestor) else { return file(.whole) }
            baseText = text
        }
        return file(.text(try mergeText(base: baseText, ours: ourText, theirs: theirText)))
    }

    /// Writes a conflicted file's resolved text to the working tree, with the
    /// line ending and other conversions a checkout would make, and stages
    /// it, which marks it resolved.
    public func saveResolution(of file: ConflictFile, text: String) throws {
        guard case .text = file.content else { throw ConflictError.notText(path: file.path) }
        guard let workingDirectory = git_repository_workdir(pointer).map({ String(cString: $0) }) else {
            throw RepositoryError.noWorkingDirectory
        }
        try requireUnchanged(file)

        var bytes = Data(text.utf8)
        var filters: OpaquePointer?
        try check(git_filter_list_load(&filters, pointer, nil, file.path, GIT_FILTER_TO_WORKTREE, GIT_FILTER_DEFAULT.rawValue))
        if let filters {
            defer { git_filter_list_free(filters) }
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            try bytes.withUnsafeBytes { raw in
                let start = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
                _ = try check(git_filter_list_apply_to_buffer(&buffer, filters, start, raw.count))
            }
            bytes = buffer.ptr.map { Data(bytes: $0, count: buffer.size) } ?? Data()
        }

        let url = URL(filePath: workingDirectory).appending(path: file.path)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Not atomic: writing over the file in place keeps its permissions.
        try bytes.write(to: url)
        if !existed, let ours = try stageMode(of: file.path, stage: 2), ours == 0o100755 {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try stage([file.path])
    }

    /// What the sides of the conflicts are, from the operation under way.
    public func conflictLabels() throws -> ConflictLabels {
        let head = try head()
        let current = ConflictSideLabel(
            role: .current, name: head.branchName.map(shortName(of:)), commit: head.target,
            summary: head.target.flatMap { try? commit($0).summary }
        )
        func side(_ role: ConflictSideLabel.Role, _ id: OID?, name: String? = nil) -> ConflictSideLabel {
            ConflictSideLabel(role: role, name: name, commit: id, summary: id.flatMap { try? commit($0).summary })
        }

        switch RepositoryState(git_repository_state(pointer)) {
        case .merging:
            let incoming = readGitFile("MERGE_HEAD").flatMap { $0.split(separator: "\n").first }
                .flatMap { OID(hex: String($0)) }
            let name = mergedName() ?? incoming.flatMap(referenceName(pointingAt:))
            return ConflictLabels(operation: .merge, ours: current, theirs: side(.incoming, incoming, name: name))
        case .rebasing:
            let directory = readGitFile("rebase-merge/head-name") != nil ? "rebase-merge" : "rebase-apply"
            let ontoID = readGitFile("\(directory)/onto").flatMap(OID.init(hex:))
            let ontoName = readGitFile("\(directory)/onto_name") ?? ontoID.flatMap(referenceName(pointingAt:))
            let branch = readGitFile("\(directory)/head-name").flatMap { $0 == "detached HEAD" ? nil : shortName(of: $0) }
            let replayed = ["REBASE_HEAD", "\(directory)/current", "\(directory)/stopped-sha"].lazy
                .compactMap { self.readGitFile($0).flatMap { self.resolveObjectName($0) } }.first
            return ConflictLabels(
                operation: .rebase,
                ours: ConflictSideLabel(
                    role: .onto, name: ontoName.map(shortName(of:)), commit: head.target,
                    summary: head.target.flatMap { try? commit($0).summary }
                ),
                theirs: side(.replayed, replayed, name: branch)
            )
        case .cherryPicking:
            let picked = readGitFile("CHERRY_PICK_HEAD").flatMap(OID.init(hex:))
            return ConflictLabels(operation: .cherryPick, ours: current, theirs: side(.picked, picked))
        case .reverting:
            let reverted = readGitFile("REVERT_HEAD").flatMap(OID.init(hex:))
            return ConflictLabels(operation: .revert, ours: current, theirs: side(.reverted, reverted))
        default:
            // Conflicts with nothing under way, as applying a stash leaves.
            return ConflictLabels(operation: nil, ours: current, theirs: side(.incoming, nil))
        }
    }

    // MARK: Merging the text

    /// Merges three versions of a file with libgit2's merge-file, the same
    /// xdiff merge git uses, in diff3 style, and reads the result.
    func mergeText(base: [UInt8], ours: [UInt8], theirs: [UInt8]) throws -> MergeText {
        // Markers longer than any run in the content, so none is mistaken for one.
        let markerSize = max(Int(GIT_MERGE_CONFLICT_MARKER_SIZE), MergeText.longestMarkerRun(in: [base, ours, theirs]) + 1)
        var options = git_merge_file_options()
        try check(git_merge_file_options_init(&options, UInt32(GIT_MERGE_FILE_OPTIONS_VERSION)))
        options.flags = GIT_MERGE_FILE_STYLE_DIFF3.rawValue
        options.marker_size = UInt16(min(markerSize, Int(UInt16.max)))

        var result = git_merge_file_result()
        defer { git_merge_file_result_free(&result) }
        try base.withUnsafeBufferPointer { base in
            try ours.withUnsafeBufferPointer { ours in
                try theirs.withUnsafeBufferPointer { theirs in
                    var inputs = [base, ours, theirs].map { buffer in
                        var input = git_merge_file_input()
                        input.version = UInt32(GIT_MERGE_FILE_INPUT_VERSION)
                        input.ptr = UnsafeRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: CChar.self)
                        input.size = buffer.count
                        return input
                    }
                    _ = try check(git_merge_file(&result, &inputs[0], &inputs[1], &inputs[2], &options))
                }
            }
        }
        let output = result.ptr.map { pointer in
            Array(UnsafeRawBufferPointer(start: pointer, count: result.len))
        } ?? []
        func endsOpen(_ bytes: [UInt8]) -> Bool { bytes.last.map { $0 != UInt8(ascii: "\n") } ?? false }
        return MergeText.parse(
            output, markerSize: markerSize,
            sidesEndOpen: (base: endsOpen(base), ours: endsOpen(ours), theirs: endsOpen(theirs))
        )
    }

    // MARK: Helpers

    /// A stage's contents, or `nil` if it is binary or not UTF-8.
    private func textOfBlob(_ entry: UnsafePointer<git_index_entry>) throws -> [UInt8]? {
        var id = entry.pointee.id
        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, pointer, &id))
        defer { git_blob_free(blob) }
        guard git_blob_is_binary(blob) == 0 else { return nil }
        let size = Int(git_blob_rawsize(blob))
        let bytes = git_blob_rawcontent(blob).map { Array(UnsafeRawBufferPointer(start: $0, count: size)) } ?? []
        guard String(validating: bytes, as: UTF8.self) != nil else { return nil }
        return bytes
    }

    private static func isRegularFile(_ mode: UInt32) -> Bool {
        mode == 0o100644 || mode == 0o100755
    }

    private func requireUnchanged(_ file: ConflictFile) throws {
        let index = try branchingIndex()
        defer { git_index_free(index) }
        var ancestor: UnsafePointer<git_index_entry>?
        var ours: UnsafePointer<git_index_entry>?
        var theirs: UnsafePointer<git_index_entry>?
        guard git_index_conflict_get(&ancestor, &ours, &theirs, index, file.path) == 0,
              [ancestor, ours, theirs].map({ $0.map { OID($0.pointee.id) } }) == file.stages else {
            throw ConflictError.changed(path: file.path)
        }
    }

    private func stageMode(of path: String, stage: Int32) throws -> UInt32? {
        let index = try branchingIndex()
        defer { git_index_free(index) }
        return git_index_get_bypath(index, path, stage)?.pointee.mode
    }

    /// The name a merge was started with, from git's own merge message.
    private func mergedName() -> String? {
        guard let line = readGitFile("MERGE_MSG")?.split(separator: "\n").first.map(String.init) else { return nil }
        for prefix in ["Merge remote-tracking branch '", "Merge branch '", "Merge tag '"] where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            if let end = rest.firstIndex(of: "'") { return String(rest[..<end]) }
        }
        return nil
    }

    /// A local branch, remote branch or tag at a commit, in that order of preference.
    func referenceName(pointingAt id: OID) -> String? {
        for glob in ["refs/heads/*", "refs/remotes/*", "refs/tags/*"] {
            var iterator: OpaquePointer?
            guard git_reference_iterator_glob_new(&iterator, pointer, glob) == 0 else { continue }
            defer { git_reference_iterator_free(iterator) }
            var reference: OpaquePointer?
            while git_reference_next(&reference, iterator) == 0 {
                defer { git_reference_free(reference) }
                var object: OpaquePointer?
                guard git_reference_peel(&object, reference, GIT_OBJECT_COMMIT) == 0 else { continue }
                defer { git_object_free(object) }
                if OID(git_object_id(object)) == id, let name = git_reference_shorthand(reference) {
                    let short = String(cString: name)
                    if short != "HEAD" && !short.hasSuffix("/HEAD") { return short }
                }
            }
        }
        return nil
    }

    private func resolveObjectName(_ name: String) -> OID? {
        var object: OpaquePointer?
        guard git_revparse_single(&object, pointer, name) == 0 else { return nil }
        defer { git_object_free(object) }
        return OID(git_object_id(object))
    }
}
