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

/// Which commits of a history to keep, beyond a text search: a range of
/// dates and a choice of authors. Keeps the history's order.
public struct HistoryFilter: Hashable, Sendable {
    /// Someone who wrote commits, as git records them.
    public struct Author: Hashable, Sendable, Comparable {
        public var name: String
        public var email: String

        public init(name: String, email: String) {
            self.name = name
            self.email = email
        }

        public static func < (lhs: Author, rhs: Author) -> Bool {
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.email < rhs.email : order == .orderedAscending
        }
    }

    /// Commits made at or after this moment, by committer date, as
    /// `git log --since` takes it.
    public var since: Date?
    /// Commits made at or before this moment, by committer date, as
    /// `git log --until` takes it.
    public var until: Date?
    /// When not empty, only commits by one of these authors.
    public var authors: Set<Author>

    public init(since: Date? = nil, until: Date? = nil, authors: Set<Author> = []) {
        self.since = since
        self.until = until
        self.authors = authors
    }

    /// Whether it lets every commit through.
    public var isEmpty: Bool { since == nil && until == nil && authors.isEmpty }

    /// Whether a commit, by its author and committer, passes.
    public func admits(author: Signature, committer: Signature) -> Bool {
        if let since, committer.date < since { return false }
        if let until, committer.date > until { return false }
        if !authors.isEmpty, !authors.contains(Author(name: author.name, email: author.email)) { return false }
        return true
    }
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
    ///
    /// `filter` narrows the matches further, by date and author.
    public func nextMatches(
        from cursor: HistoryCursor, matching query: HistoryQuery, filter: HistoryFilter = HistoryFilter(),
        limit: Int, examining budget: Int = 2_000
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
            if !filter.isEmpty, !filter.admits(author: Signature(git_commit_author(commit!).pointee),
                                                committer: Signature(git_commit_committer(commit!).pointee)) {
                continue
            }
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
