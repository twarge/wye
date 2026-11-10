import Clibgit2
import Foundation

/// What to look for in a history.
public struct HistoryQuery: Hashable, Sendable {
    public enum Field: String, CaseIterable, Hashable, Sendable {
        /// Anywhere in the commit message, ignoring case.
        case message
        /// In the author's `Name <email>`, ignoring case.
        case author
        /// The start of the commit's hash.
        case hash
        /// Commits that changed a file, or anything inside a folder.
        case path
    }

    public var field: Field
    public var text: String

    public init(_ field: Field, _ text: String) {
        self.field = field
        self.text = text
    }

    /// The text as searched for: trimmed, and for a path without the slashes
    /// at either end, so `src/` and `src` find the same commits.
    var term: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .message, .author: return trimmed
        case .hash: return trimmed.lowercased()
        case .path: return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    public var isEmpty: Bool { term.isEmpty }
}

/// One page of a search: the matches found among the commits examined.
public struct SearchPage: Hashable, Sendable {
    public var matches: [Commit]
    /// How many commits this page looked at, matching or not.
    public var examined: Int
    /// Whether the history has been searched to its end.
    public var isComplete: Bool
}

extension Repository {
    /// Searches on through a history opened with `openHistory`, keeping its
    /// order. Returns after `limit` matches or `examining` commits, whichever
    /// comes first, so a search for something rare in a large repository
    /// still hands the actor back between pages and can be abandoned by
    /// closing the cursor.
    ///
    /// A path matches a commit whose version of it differs from each of its
    /// parents'. For ordinary commits that is `git log --full-history --
    /// <path>`. A merge is listed only when it changed the path itself, as in
    /// resolving a conflict there, rather than whenever one side brought in a
    /// change: those changes are listed already, as the commits that made them.
    public func nextMatches(
        from cursor: HistoryCursor, matching query: HistoryQuery, limit: Int, examining budget: Int = 2_000
    ) throws -> SearchPage {
        guard let walk = walks[cursor] else { return SearchPage(matches: [], examined: 0, isComplete: true) }
        let term = query.term
        var page = SearchPage(matches: [], examined: 0, isComplete: false)
        var oid = git_oid()
        while page.matches.count < limit, page.examined < budget {
            let code = git_revwalk_next(&oid, walk.pointer)
            if code == GIT_ITEROVER.rawValue {
                page.isComplete = true
                break
            }
            try check(code)
            page.examined += 1
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, pointer, &oid))
            defer { git_commit_free(commit) }
            if try term.isEmpty || matches(commit!, field: query.field, term: term) {
                page.matches.append(Commit(commit!))
            }
        }
        return page
    }

    private func matches(_ commit: OpaquePointer, field: HistoryQuery.Field, term: String) throws -> Bool {
        switch field {
        case .message:
            let message = git_commit_message(commit).map { String(cString: $0) } ?? ""
            return message.range(of: term, options: .caseInsensitive) != nil
        case .author:
            let author = Signature(git_commit_author(commit).pointee)
            return "\(author.name) <\(author.email)>".range(of: term, options: .caseInsensitive) != nil
        case .hash:
            return OID(git_commit_id(commit)).hex.hasPrefix(term)
        case .path:
            return try changes(term, in: commit)
        }
    }

    /// Whether a commit's version of `path` differs from each of its parents'.
    /// Compares tree entries rather than building a diff: a folder's entry
    /// changes whenever anything inside it does, so this is cheap.
    func changes(_ path: String, in commit: OpaquePointer) throws -> Bool {
        let tree = try self.tree(of: commit)
        defer { git_tree_free(tree) }
        let own = entryKey(at: path, in: tree)
        let parentCount = git_commit_parentcount(commit)
        guard parentCount > 0 else { return own != nil }
        for index in 0..<parentCount {
            var parent: OpaquePointer?
            try check(git_commit_parent(&parent, commit, index))
            defer { git_commit_free(parent) }
            let parentTree = try self.tree(of: parent)
            defer { git_tree_free(parentTree) }
            if entryKey(at: path, in: parentTree) == own { return false }
        }
        return true
    }
}
