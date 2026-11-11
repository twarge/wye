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
    /// The path of another worktree that has this branch checked out, for
    /// a local branch. git will not check it out here or delete it.
    public var worktreePath: String? = nil

    public struct Upstream: Hashable, Sendable {
        public let name: String
        public let ahead: Int
        public let behind: Int

        public init(name: String, ahead: Int, behind: Int) {
            self.name = name
            self.ahead = ahead
            self.behind = behind
        }
    }

    /// For tests and previews; branches are read with `snapshot()`.
    public init(
        id: String, name: String, target: OID, isRemote: Bool = false, isHead: Bool = false,
        upstream: Upstream? = nil, worktreePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.isRemote = isRemote
        self.isHead = isHead
        self.upstream = upstream
        self.worktreePath = worktreePath
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

    /// For tests and previews; tags are read with `snapshot()`.
    public init(id: String, name: String, target: OID, isAnnotated: Bool = false) {
        self.id = id
        self.name = name
        self.target = target
        self.isAnnotated = isAnnotated
    }
}

public struct Remote: Identifiable, Hashable, Sendable {
    public let name: String
    public let url: String?
    public let branches: [Branch]

    public var id: String { name }

    /// For tests and previews; remotes are read with `snapshot()`.
    public init(name: String, url: String?, branches: [Branch]) {
        self.name = name
        self.url = url
        self.branches = branches
    }
}

public struct Stash: Identifiable, Hashable, Sendable {
    /// The stash's commit.
    public let id: OID
    /// Position in the stash list; `0` is the most recent.
    public let index: Int
    public let message: String
    public let date: Date

    /// For tests and previews; stashes are read with `snapshot()`.
    public init(id: OID, index: Int, message: String, date: Date) {
        self.id = id
        self.index = index
        self.message = message
        self.date = date
    }
}

public struct Submodule: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    /// The URL `.gitmodules` gives, which may be relative to the
    /// superproject's remote (`../other.git`).
    public let url: String?
    /// The commit the superproject's `HEAD` records for it.
    public let headID: OID?
    /// The commit the index records for it: what a commit would record.
    public var indexID: OID? = nil
    /// The commit checked out in its working tree, when it is cloned.
    public var checkedOutID: OID? = nil
    /// The branch `.gitmodules` says it follows, if any.
    public var branch: String? = nil
    /// The URL its clone uses: the one in the superproject's configuration
    /// once initialized, otherwise `url` resolved as git resolves it.
    public var resolvedURL: String? = nil
    public var status: SubmoduleState = .upToDate
    /// What differs inside its working tree.
    public var changes: SubmoduleChanges = []

    public var id: String { name }

    public init(name: String, path: String, url: String?, headID: OID?) {
        self.name = name
        self.path = path
        self.url = url
        self.headID = headID
    }

    /// The commit the superproject records: the index's, or `HEAD`'s.
    public var recordedID: OID? { indexID ?? headID }
}

/// Where a submodule stands, as `git submodule status` sees it.
public enum SubmoduleState: Hashable, Sendable {
    /// Listed in `.gitmodules`, but not in the superproject's configuration.
    case notInitialized
    /// Initialized, but nothing is cloned in its folder yet.
    case notCloned
    /// Checked out at the recorded commit, with nothing changed.
    case upToDate
    /// Checked out at another commit than the superproject records.
    case differentCommit
    /// At the recorded commit, with uncommitted changes inside.
    case modifiedContent
    /// Its folder is gone from the working tree.
    case missing
}

/// What changed in a submodule's working tree, as the superproject's status
/// reports it.
public struct SubmoduleChanges: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Checked out at another commit than the index records.
    public static let newCommits = SubmoduleChanges(rawValue: 1 << 0)
    /// Tracked files inside it are changed.
    public static let modifiedContent = SubmoduleChanges(rawValue: 1 << 1)
    /// It has untracked files.
    public static let untrackedContent = SubmoduleChanges(rawValue: 1 << 2)
}

public struct Worktree: Identifiable, Hashable, Sendable {
    /// git's name for a linked worktree, the folder under
    /// `.git/worktrees`. Empty for the main worktree.
    public let name: String
    public let path: String
    public let isLocked: Bool
    /// Why it is locked, when a reason was given.
    public var lockReason: String? = nil
    /// What its `HEAD` points at; `nil` when it cannot be read.
    public var head: Head? = nil
    /// The repository's own working tree, rather than a linked one.
    public var isMain = false
    /// The worktree this repository was opened as.
    public var isCurrent = false
    /// Its folder is gone: git can prune it, unless it is locked.
    public var isMissing = false
    /// Whether its folder could be looked at. A sandboxed app cannot look
    /// at a folder it was not given; that is not the same as it being gone.
    public var isReachable = true

    public var id: String { name }

    public init(name: String, path: String, isLocked: Bool) {
        self.name = name
        self.path = path
        self.isLocked = isLocked
    }

    /// Whether `git worktree prune` would remove it.
    public var isPrunable: Bool { isMissing && !isLocked && !isMain }

    /// The worktree's folder name, as people tell worktrees apart.
    public var displayName: String {
        URL(filePath: path).lastPathComponent
    }
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

    /// For tests and previews; a snapshot is read with `snapshot()`.
    public init(
        head: Head, state: RepositoryState = .clean, branches: [Branch] = [], remotes: [Remote] = [],
        tags: [Tag] = [], stashes: [Stash] = [], submodules: [Submodule] = [], worktrees: [Worktree] = []
    ) {
        self.head = head
        self.state = state
        self.branches = branches
        self.remotes = remotes
        self.tags = tags
        self.stashes = stashes
        self.submodules = submodules
        self.worktrees = worktrees
    }
}

/// Which commits a history lists.
public enum HistoryScope: Hashable, Sendable {
    /// Everything reachable from any branch, remote branch, tag or `HEAD`.
    case allReferences
    /// Everything reachable from one reference, given by its full name.
    case reference(String)
}
