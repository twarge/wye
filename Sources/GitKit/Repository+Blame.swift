import Clibgit2
import Foundation

/// Who last changed each line of a file, as of one commit.
public struct Blame: Hashable, Sendable {
    public let path: String
    /// The commit the file was read at.
    public let commitID: OID
    /// Consecutive lines last changed by the same commit, in file order.
    public let runs: [Run]

    public var lineCount: Int { runs.reduce(0) { $0 + $1.lines.count } }

    public struct Run: Identifiable, Hashable, Sendable {
        public let commitID: OID
        public let author: Signature
        public let summary: String
        /// The file's path in that commit, which differs after a rename.
        public let originalPath: String
        /// The number of the run's first line, counting from 1.
        public let startLine: Int
        public let lines: [String]
        /// Whether the lines go back to the first commit of the history, so
        /// they may be older than the commit says.
        public let isBoundary: Bool

        public var id: Int { startLine }
    }
}

extension Repository {
    /// Blames the file at `path` as it is in a commit.
    ///
    /// libgit2 has no way to blame part of a file at a time, so this is one
    /// call; it is as quick as the file's history is short.
    public func blame(of path: String, at commitID: OID) throws -> Blame {
        let content = try fileContent(at: path, in: commitID, limit: .max)
        let text: String
        switch content.contents {
        case .text(let string): text = string
        case .binary, .tooLarge:
            throw GitError(code: GIT_EINVALID.rawValue, message: "“\(path)” is not a text file.")
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        if text.hasSuffix("\n") { lines.removeLast() }

        var options = git_blame_options()
        try check(git_blame_options_init(&options, UInt32(GIT_BLAME_OPTIONS_VERSION)))
        options.newest_commit = commitID.raw
        var blame: OpaquePointer?
        try check(git_blame_file(&blame, pointer, path, &options))
        defer { git_blame_free(blame) }

        var summaries: [OID: String] = [:]
        var runs: [Blame.Run] = []
        for index in 0..<git_blame_hunkcount(blame) {
            guard let hunk = git_blame_hunk_byindex(blame, index)?.pointee else { continue }
            let id = OID(hunk.final_commit_id)
            let start = hunk.final_start_line_number
            guard start >= 1, start <= lines.count else { continue }
            let range = (start - 1)..<min(start - 1 + hunk.lines_in_hunk, lines.count)
            let hunkLines = Array(lines[range])

            // libgit2 can split one commit's lines into neighbouring hunks.
            if let last = runs.last, last.commitID == id, last.startLine + last.lines.count == start {
                runs[runs.count - 1] = Blame.Run(
                    commitID: id, author: last.author, summary: last.summary, originalPath: last.originalPath,
                    startLine: last.startLine, lines: last.lines + hunkLines, isBoundary: last.isBoundary
                )
                continue
            }
            if summaries[id] == nil {
                summaries[id] = (try? commit(id))?.summary ?? ""
            }
            let author = hunk.final_signature.map { Signature($0.pointee) }
                ?? (try? commit(id))?.author
                ?? Signature(name: "", email: "", date: .distantPast)
            runs.append(Blame.Run(
                commitID: id,
                author: author,
                summary: summaries[id] ?? "",
                originalPath: hunk.orig_path.map { String(cString: $0) } ?? path,
                startLine: start,
                lines: hunkLines,
                isBoundary: hunk.boundary != 0
            ))
        }
        return Blame(path: path, commitID: commitID, runs: runs)
    }
}
