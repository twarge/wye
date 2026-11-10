import Clibgit2
import Foundation

/// Where an ignore rule is written.
public enum IgnoreFile: Hashable, Sendable, CaseIterable {
    /// The `.gitignore` at the top of the working tree, committed and shared
    /// with everyone who clones the repository.
    case shared
    /// `.git/info/exclude`, which stays in this clone.
    case local
}

/// Ignore patterns for a path, written so that they match that path and
/// nothing that merely looks like it.
public enum IgnorePattern {
    /// Matches one file, and only at its place in the tree.
    public static func file(_ path: String) -> String {
        "/" + escaped(trimmed(path))
    }

    /// Matches one folder and everything in it.
    public static func folder(_ path: String) -> String {
        "/" + escaped(trimmed(path)) + "/"
    }

    /// Matches every file with the extension of `path`, in any folder, or
    /// `nil` when its name has no extension.
    public static func fileExtension(of path: String) -> String? {
        guard let name = trimmed(path).split(separator: "/").last,
              let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return nil }
        return "*" + escaped(String(name[dot...]))
    }

    /// The extension a pattern from `fileExtension(of:)` names, for showing,
    /// such as `.log`.
    public static func extensionName(of path: String) -> String? {
        guard let name = trimmed(path).split(separator: "/").last,
              let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return nil }
        return String(name[dot...])
    }

    private static func trimmed(_ path: String) -> String {
        var path = Substring(path)
        while path.hasPrefix("/") { path = path.dropFirst() }
        while path.hasSuffix("/") { path = path.dropLast() }
        return String(path)
    }

    /// Escapes what ignore patterns treat specially: wildcards, a leading
    /// `#` or `!`, and spaces at the end, which git would otherwise drop.
    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\", "*", "?", "[": result += "\\" + String(character)
            default: result.append(character)
            }
        }
        if result.hasPrefix("#") || result.hasPrefix("!") {
            result = "\\" + result
        }
        var trailingSpaces = 0
        while result.hasSuffix(" ") {
            result.removeLast()
            trailingSpaces += 1
        }
        return result + String(repeating: "\\ ", count: trailingSpaces)
    }
}

extension Repository {
    // MARK: Ignore files

    /// The rules in an ignore file, in order: every line that is not blank
    /// and not a comment. Empty when the file does not exist.
    public func ignorePatterns(in file: IgnoreFile) throws -> [String] {
        try ignoreFileLines(file).filter { line in
            !line.trimmingCharacters(in: .whitespaces).isEmpty && !line.hasPrefix("#")
        }
    }

    /// Adds rules to the end of an ignore file, creating it if need be. A
    /// rule the file already has is not added again.
    public func addIgnorePatterns(_ patterns: [String], to file: IgnoreFile) throws {
        var lines = try ignoreFileLines(file)
        var existing = Set(lines)
        var added = false
        for pattern in patterns {
            let pattern = pattern.trimmingCharacters(in: .newlines)
            guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty, !existing.contains(pattern) else { continue }
            lines.append(pattern)
            existing.insert(pattern)
            added = true
        }
        guard added else { return }
        try writeIgnoreFile(file, lines: lines)
    }

    /// Removes every line of an ignore file that is one of `patterns`,
    /// leaving comments and the other rules as they are.
    public func removeIgnorePatterns(_ patterns: Set<String>, from file: IgnoreFile) throws {
        let lines = try ignoreFileLines(file)
        let kept = lines.filter { !patterns.contains($0) }
        guard kept.count != lines.count else { return }
        try writeIgnoreFile(file, lines: kept)
    }

    /// Whether the ignore rules match a path, tracked or not, as
    /// `git check-ignore --no-index` answers.
    public func isIgnored(_ path: String) throws -> Bool {
        var ignored: Int32 = 0
        try check(git_ignore_path_is_ignored(&ignored, pointer, path))
        return ignored != 0
    }

    /// The tracked files that the ignore rules match. git keeps tracking
    /// them regardless, so a rule written for one of them only takes effect
    /// once it stops being tracked.
    public func trackedIgnoredPaths() throws -> Set<String> {
        let index = try freshIndex()
        defer { git_index_free(index) }
        var paths: Set<String> = []
        for position in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, position)?.pointee, let raw = entry.path else { continue }
            let path = String(cString: raw)
            if try isIgnored(path) { paths.insert(path) }
        }
        return paths
    }

    /// The files and folders that are ignored and hold nothing tracked, as
    /// `git status --ignored` lists them: a folder that is ignored as a whole
    /// is one entry, its path ending in `/`.
    public func ignoredPaths() throws -> [String] {
        guard !isBare else { return [] }
        var options = git_status_options()
        try check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)))
        options.show = GIT_STATUS_SHOW_WORKDIR_ONLY
        options.flags = GIT_STATUS_OPT_INCLUDE_IGNORED.rawValue
            | GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue
        var list: OpaquePointer?
        try check(git_status_list_new(&list, pointer, &options))
        defer { git_status_list_free(list) }
        return (0..<git_status_list_entrycount(list)).compactMap { position in
            guard let entry = git_status_byindex(list, position)?.pointee,
                  entry.status.rawValue & GIT_STATUS_IGNORED.rawValue != 0,
                  let raw = entry.index_to_workdir?.pointee.new_file.path else { return nil }
            return String(cString: raw)
        }
    }

    // MARK: Tracking

    /// Whether the index has a file at `path`, or any file under it as a folder.
    public func isTracked(_ path: String) throws -> Bool {
        let index = try freshIndex()
        defer { git_index_free(index) }
        return Self.contains(path, in: index)
    }

    /// Takes paths out of the index and leaves them on disk, as
    /// `git rm -r --cached` does: the next commit deletes them from the
    /// repository, and from then on they are untracked.
    public func stopTracking(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let index = try freshIndex()
        defer { git_index_free(index) }
        for path in paths {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            if git_index_get_bypath(index, trimmed, 0) != nil {
                try check(git_index_remove_bypath(index, trimmed))
            } else {
                try check(git_index_remove_directory(index, trimmed, 0))
            }
        }
        try check(git_index_write(index))
    }

    /// Sets or clears the "assume unchanged" flag on tracked files, as
    /// `git update-index --[no-]assume-unchanged` does. git then takes the
    /// file to match the index without looking, so its edits stop showing.
    public func setAssumeUnchanged(_ isAssumed: Bool, for paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let index = try freshIndex()
        defer { git_index_free(index) }
        for path in paths {
            guard var entry = git_index_get_bypath(index, path, 0)?.pointee else {
                throw GitError(code: GIT_ENOTFOUND.rawValue, message: "“\(path)” is not tracked.")
            }
            let flag = UInt16(GIT_INDEX_ENTRY_VALID.rawValue)
            entry.flags = isAssumed ? entry.flags | flag : entry.flags & ~flag
            // The entry's path belongs to the index, which `add` replaces;
            // hand it a copy.
            let copy = strdup(path)
            defer { free(copy) }
            entry.path = UnsafePointer(copy)
            try check(git_index_add(index, &entry))
        }
        try check(git_index_write(index))
    }

    /// The tracked files marked "assume unchanged", in the index's order.
    public func assumeUnchangedPaths() throws -> [String] {
        let index = try freshIndex()
        defer { git_index_free(index) }
        let flag = UInt16(GIT_INDEX_ENTRY_VALID.rawValue)
        return (0..<git_index_entrycount(index)).compactMap { position in
            guard let entry = git_index_get_byindex(index, position)?.pointee,
                  entry.flags & flag != 0, let raw = entry.path else { return nil }
            return String(cString: raw)
        }
    }

    // MARK: Helpers

    /// The repository's index, read again from disk. The caller frees it.
    func freshIndex() throws -> OpaquePointer? {
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        // Pick up changes another git made since this repository was opened.
        try check(git_index_read(index, 0))
        return index
    }

    static func contains(_ path: String, in index: OpaquePointer?) -> Bool {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if git_index_get_bypath(index, trimmed, 0) != nil { return true }
        var position = 0
        return git_index_find_prefix(&position, index, trimmed + "/") == 0
    }

    private func ignoreFileURL(_ file: IgnoreFile) throws -> URL {
        switch file {
        case .shared:
            guard let workingDirectory = git_repository_workdir(pointer).map({ String(cString: $0) }) else {
                throw RepositoryError.noWorkingDirectory
            }
            return URL(filePath: workingDirectory, directoryHint: .isDirectory).appending(path: ".gitignore")
        case .local:
            // Shared by every worktree of the repository, as git reads it.
            let common = String(cString: git_repository_commondir(pointer))
            return URL(filePath: common, directoryHint: .isDirectory).appending(path: "info/exclude")
        }
    }

    /// Every line of an ignore file, without line endings.
    private func ignoreFileLines(_ file: IgnoreFile) throws -> [String] {
        let url = try ignoreFileURL(file)
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private func writeIgnoreFile(_ file: IgnoreFile, lines: [String]) throws {
        let url = try ignoreFileURL(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
