import Clibgit2
import Foundation

/// What an archive written from a commit holds.
public struct ArchiveSummary: Hashable, Sendable {
    public var files: Int
    /// Submodules, which are written as empty folders: their files are in
    /// another repository.
    public var submodules: Int
}

extension Repository {
    /// Writes the files of a commit's tree to a zip archive at `url`, as
    /// `git archive --format=zip` does: every file and folder, executable
    /// bits and symbolic links kept, each dated with the commit's time.
    /// `prefix`, such as `project-v1.0/`, is put before every path.
    /// Submodules become empty folders. `.gitattributes`' `export-ignore`
    /// and `export-subst` are not applied.
    @discardableResult
    public func writeArchive(of commitID: OID, to url: URL, prefix: String = "") throws -> ArchiveSummary {
        let commit = try lookupCommit(commitID)
        defer { git_commit_free(commit) }
        let root = try tree(of: commit)
        defer { git_tree_free(root) }
        let date = Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))
        let writer = try ZipWriter(url: url)
        var summary = ArchiveSummary(files: 0, submodules: 0)
        do {
            let prefix = prefix.isEmpty || prefix.hasSuffix("/") ? prefix : prefix + "/"
            if !prefix.isEmpty {
                try writer.addDirectory(prefix, date: date)
            }
            try writeTree(root, path: prefix, to: writer, date: date, summary: &summary)
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return summary
    }

    private func writeTree(
        _ tree: OpaquePointer?, path: String, to writer: ZipWriter, date: Date, summary: inout ArchiveSummary
    ) throws {
        for index in 0..<git_tree_entrycount(tree) {
            guard let entry = git_tree_entry_byindex(tree, index) else { continue }
            let name = path + String(cString: git_tree_entry_name(entry))
            switch git_tree_entry_filemode(entry) {
            case GIT_FILEMODE_TREE:
                try writer.addDirectory(name, date: date)
                var object: OpaquePointer?
                try check(git_tree_entry_to_object(&object, pointer, entry))
                defer { git_object_free(object) }
                try writeTree(object, path: name + "/", to: writer, date: date, summary: &summary)
            case GIT_FILEMODE_COMMIT:
                try writer.addDirectory(name, date: date)
                summary.submodules += 1
            case let mode:
                var blob: OpaquePointer?
                try check(git_blob_lookup(&blob, pointer, git_tree_entry_id(entry)))
                defer { git_blob_free(blob) }
                let data = Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
                if mode == GIT_FILEMODE_LINK {
                    try writer.addSymbolicLink(name, target: String(decoding: data, as: UTF8.self), date: date)
                } else {
                    try writer.addFile(name, data: data, executable: mode == GIT_FILEMODE_BLOB_EXECUTABLE, date: date)
                }
                summary.files += 1
            }
        }
    }
}
