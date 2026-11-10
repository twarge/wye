import Foundation

/// Who made a change, and when.
public struct Signature: Hashable, Sendable {
    public var name: String
    public var email: String
    public var date: Date
    /// The author's offset from UTC when the change was made.
    public var timeZone: TimeZone

    public init(name: String, email: String, date: Date, timeZone: TimeZone = .gmt) {
        self.name = name
        self.email = email
        self.date = date
        self.timeZone = timeZone
    }
}

public struct Commit: Identifiable, Hashable, Sendable {
    public let id: OID
    public let parentIDs: [OID]
    public let treeID: OID
    public let author: Signature
    public let committer: Signature
    /// The first paragraph of the message, on one line.
    public let summary: String
    /// The rest of the message, without the summary.
    public let body: String

    public init(
        id: OID, parentIDs: [OID], treeID: OID, author: Signature, committer: Signature, summary: String, body: String
    ) {
        self.id = id
        self.parentIDs = parentIDs
        self.treeID = treeID
        self.author = author
        self.committer = committer
        self.summary = summary
        self.body = body
    }

    public var isMerge: Bool { parentIDs.count > 1 }
}

/// What `HEAD` points at.
public enum Head: Hashable, Sendable {
    /// On a branch, given by its full reference name.
    case branch(name: String, target: OID)
    case detached(OID)
    /// On a branch that has no commits yet.
    case unborn(name: String)

    public var target: OID? {
        switch self {
        case .branch(_, let target), .detached(let target): target
        case .unborn: nil
        }
    }

    public var branchName: String? {
        switch self {
        case .branch(let name, _), .unborn(let name): name
        case .detached: nil
        }
    }
}

/// An operation the repository is in the middle of.
public enum RepositoryState: Hashable, Sendable {
    case clean
    case merging
    case reverting
    case cherryPicking
    case bisecting
    case rebasing
    case applyingMailbox
}

public struct Branch: Identifiable, Hashable, Sendable {
    /// The full reference name, such as `refs/heads/main`.
    public let id: String
    /// The name as people write it: `main`, or `origin/main` for a remote branch.
    public let name: String
    public let target: OID
    public let isRemote: Bool
    public let isHead: Bool
    public let upstream: Upstream?

    public struct Upstream: Hashable, Sendable {
        public let name: String
        public let ahead: Int
        public let behind: Int
    }

    /// A remote branch's name without its remote: `main` for `origin/main`.
    public var nameWithoutRemote: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

public struct Tag: Identifiable, Hashable, Sendable {
    /// The full reference name, such as `refs/tags/v1.0`.
    public let id: String
    public let name: String
    /// The commit the tag leads to.
    public let target: OID
    public let isAnnotated: Bool
}

public struct Remote: Identifiable, Hashable, Sendable {
    public let name: String
    public let url: String?
    public let branches: [Branch]

    public var id: String { name }
}

public struct Stash: Identifiable, Hashable, Sendable {
    /// The stash's commit.
    public let id: OID
    /// Position in the stash list; `0` is the most recent.
    public let index: Int
    public let message: String
    public let date: Date
}

public struct Submodule: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let url: String?
    /// The commit the superproject records for it.
    public let headID: OID?

    public var id: String { name }
}

public struct Worktree: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let isLocked: Bool

    public var id: String { name }
}

/// Everything the sidebar shows, read in one pass.
public struct RepositorySnapshot: Hashable, Sendable {
    public var head: Head
    public var state: RepositoryState
    public var branches: [Branch]
    public var remotes: [Remote]
    public var tags: [Tag]
    public var stashes: [Stash]
    public var submodules: [Submodule]
    public var worktrees: [Worktree]
}

/// Which commits a history lists.
public enum HistoryScope: Hashable, Sendable {
    /// Everything reachable from any branch, remote branch, tag or `HEAD`.
    case allReferences
    /// Everything reachable from one reference, given by its full name.
    case reference(String)
}
