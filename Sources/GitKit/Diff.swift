import Foundation

/// How a file differs between two sides of a comparison.
public enum FileChange: Hashable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflicted
}

/// Where a side of a comparison is read from: a commit, the index, or the
/// files in the working tree.
public enum ContentSource: Hashable, Sendable {
    /// A commit's tree. A tree's own ID works as well.
    case commit(OID)
    case index
    case workingTree
}

/// One file's changes.
public struct FileDiff: Identifiable, Hashable, Sendable {
    public var change: FileChange
    /// The path before the change; differs from `path` for a rename or copy.
    public var oldPath: String
    public var path: String
    public var isBinary: Bool
    public var additions: Int
    public var deletions: Int
    public var hunks: [Hunk]
    /// Whether lines were left out because the file's diff is very long.
    public var isTruncated: Bool
    /// For a submodule, the commits it records on each side in place of
    /// lines, which a submodule has none of.
    public var submodule: SubmoduleChange? = nil
    /// The blob on each side, where git knows it: `nil` on the side where the
    /// file does not exist, and for a working tree file git has not hashed.
    public var oldBlobID: OID? = nil
    public var newBlobID: OID? = nil
    /// What each side of the diff as a whole was read from, so that the
    /// folder around a file, such as a document package, can be put back
    /// together as that side has it. `nil` for an empty side, such as the
    /// parent of a first commit.
    public var oldSource: ContentSource? = nil
    public var newSource: ContentSource? = nil

    /// Whether the new side is the file in the working tree rather than a
    /// blob, as in an unstaged diff.
    public var newSideIsWorkingTree: Bool { newSource == .workingTree }

    public var id: String { path }

    public init(
        change: FileChange, oldPath: String, path: String, isBinary: Bool, additions: Int, deletions: Int,
        hunks: [Hunk], isTruncated: Bool, submodule: SubmoduleChange? = nil
    ) {
        self.change = change
        self.oldPath = oldPath
        self.path = path
        self.isBinary = isBinary
        self.additions = additions
        self.deletions = deletions
        self.hunks = hunks
        self.isTruncated = isTruncated
        self.submodule = submodule
    }

    public struct Hunk: Identifiable, Hashable, Sendable {
        public var id: Int
        /// The `@@ -1,5 +1,7 @@` line.
        public var header: String
        public var lines: [Line]

        public init(id: Int, header: String, lines: [Line]) {
            self.id = id
            self.header = header
            self.lines = lines
        }
    }

    public struct Line: Identifiable, Hashable, Sendable {
        public var id: Int
        public var kind: Kind
        public var oldNumber: Int?
        public var newNumber: Int?
        public var text: String

        public init(id: Int, kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
            self.id = id
            self.kind = kind
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.text = text
        }

        public enum Kind: Hashable, Sendable {
            case context
            case addition
            case deletion
            /// The "no newline at end of file" marker.
            case noNewline
        }
    }
}

/// A file in the working copy that differs from `HEAD`.
public struct StatusEntry: Identifiable, Hashable, Sendable {
    public var path: String
    /// The path in `HEAD`, when the file was renamed.
    public var originalPath: String?
    /// The change between `HEAD` and the index.
    public var staged: FileChange?
    /// The change between the index and the working tree.
    public var unstaged: FileChange?
    /// For a submodule: what is changed in it.
    public var submodule: SubmoduleChanges?

    public init(path: String, originalPath: String? = nil, staged: FileChange?, unstaged: FileChange?) {
        self.path = path
        self.originalPath = originalPath
        self.staged = staged
        self.unstaged = unstaged
    }

    public var id: String { path }

    public var isConflicted: Bool { unstaged == .conflicted }

    /// The change to show when one badge has to stand for both sides.
    public var change: FileChange { unstaged ?? staged ?? .modified }
}
