import Foundation

/// An operation that can be undone, named as the Edit menu names it, and
/// what of the repository it can change: its references always, and the
/// index, the working tree and the stash list when it touches them.
///
/// Call sites say what they are about to do with one of the constructors,
/// such as `.commit` or `.reset(.hard)`.
public struct UndoOperation: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case commit, amend, reword
        case checkout
        case createBranch, renameBranch, deleteBranch, setUpstream
        case createTag, deleteTag
        case merge, cherryPick, revert, reset, rebase
        case stage, unstage
        case stashSave, stashApply, stashPop, stashDrop
        case discard
        case applyPatch
    }

    /// What, beyond references and `HEAD`, a record of the operation keeps.
    public struct Captures: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let index = Captures(rawValue: 1 << 0)
        /// The tracked files in the working tree.
        public static let workTree = Captures(rawValue: 1 << 1)
        /// Untracked files' contents too, for operations that remove them.
        public static let untracked = Captures(rawValue: 1 << 2)
        public static let stash = Captures(rawValue: 1 << 3)
    }

    public var kind: Kind
    /// The operation's name, as in "Undo Commit".
    public var title: String
    public var captures: Captures
    /// For `.untracked`: the paths whose untracked files are kept, or every
    /// untracked file when `nil`.
    public var untrackedPaths: [String]?

    public init(kind: Kind, title: String, captures: Captures = [], untrackedPaths: [String]? = nil) {
        self.kind = kind
        self.title = title
        self.captures = captures
        self.untrackedPaths = untrackedPaths
    }

    private static let everything: Captures = [.index, .workTree]

    public static let commit = UndoOperation(kind: .commit, title: "Commit")
    public static let amend = UndoOperation(kind: .amend, title: "Amend")
    public static let reword = UndoOperation(kind: .reword, title: "Edit Message")
    public static let checkout = UndoOperation(kind: .checkout, title: "Checkout", captures: everything)
    public static let createBranch = UndoOperation(kind: .createBranch, title: "New Branch")
    public static let renameBranch = UndoOperation(kind: .renameBranch, title: "Rename Branch")
    public static let deleteBranch = UndoOperation(kind: .deleteBranch, title: "Delete Branch")
    public static let setUpstream = UndoOperation(kind: .setUpstream, title: "Set Upstream")
    public static let createTag = UndoOperation(kind: .createTag, title: "New Tag")
    public static let deleteTag = UndoOperation(kind: .deleteTag, title: "Delete Tag")
    public static let merge = UndoOperation(kind: .merge, title: "Merge", captures: everything)
    public static let rebase = UndoOperation(kind: .rebase, title: "Rebase", captures: everything)
    public static let stage = UndoOperation(kind: .stage, title: "Stage", captures: .index)
    public static let unstage = UndoOperation(kind: .unstage, title: "Unstage", captures: .index)
    public static let stashApply = UndoOperation(
        kind: .stashApply, title: "Apply Stash", captures: [.index, .workTree, .untracked]
    )
    public static let stashPop = UndoOperation(
        kind: .stashPop, title: "Pop Stash", captures: [.index, .workTree, .untracked, .stash]
    )
    public static let stashDrop = UndoOperation(kind: .stashDrop, title: "Drop Stash", captures: .stash)

    public static func cherryPick(count: Int = 1) -> UndoOperation {
        UndoOperation(kind: .cherryPick, title: count == 1 ? "Cherry-Pick" : "Cherry-Pick \(count) Commits",
                      captures: everything)
    }

    public static func revert(count: Int = 1) -> UndoOperation {
        UndoOperation(kind: .revert, title: count == 1 ? "Revert" : "Revert \(count) Commits", captures: everything)
    }

    /// A reset keeps what its mode touches: nothing more for soft, the index
    /// for mixed, and the index and working tree for hard, whose changes are
    /// otherwise lost.
    public static func reset(_ mode: ResetMode) -> UndoOperation {
        switch mode {
        case .soft: UndoOperation(kind: .reset, title: "Soft Reset")
        case .mixed: UndoOperation(kind: .reset, title: "Reset", captures: .index)
        case .hard: UndoOperation(kind: .reset, title: "Hard Reset", captures: everything)
        }
    }

    public static func stashSave(includingUntracked: Bool) -> UndoOperation {
        UndoOperation(kind: .stashSave, title: "Stash Changes",
                      captures: includingUntracked ? [.index, .workTree, .untracked, .stash] : [.index, .workTree, .stash])
    }

    /// Discarding keeps a copy of what it throws away: the tracked files,
    /// and the untracked ones among `paths` (all of them when `nil`).
    public static func discard(paths: [String]? = nil) -> UndoOperation {
        UndoOperation(kind: .discard, title: "Discard Changes", captures: [.index, .workTree, .untracked],
                      untrackedPaths: paths)
    }

    public static func applyPatch(toIndex: Bool) -> UndoOperation {
        UndoOperation(kind: .applyPatch, title: "Apply Patch", captures: toIndex ? [.index] : everything)
    }
}

/// What `HEAD` points at, as recorded for undo.
public enum UndoHead: Hashable, Sendable, Codable {
    /// A branch, by full reference name, which need not have commits yet.
    case symbolic(String)
    case detached(OID)
}

/// A value before an operation and after it.
public struct UndoChange<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    public var before: Value
    public var after: Value

    public init(before: Value, after: Value) {
        self.before = before
        self.after = after
    }

    func value(_ side: UndoSide) -> Value {
        side == .before ? before : after
    }
}

/// A branch's upstream as its configuration states it.
public struct UndoUpstream: Hashable, Sendable, Codable {
    public var remote: String?
    public var merge: String?

    public var isEmpty: Bool { remote == nil && merge == nil }
}

/// One entry of the stash list.
public struct UndoStashEntry: Hashable, Sendable, Codable {
    public var id: OID
    public var message: String
}

/// The working copy at one moment: the index's tree, and a tree of the
/// working tree’s files when the operation keeps one. Both are written to the object database without
/// any reference, as a stash's are before it is stored.
public struct UndoWorkingState: Hashable, Sendable, Codable {
    public var index: OID
    public var workTree: OID?
    /// A commit holding `workTree`, made when there is an identity to make
    /// it with, so the saved files can be found with git too.
    public var commit: OID?
}

/// Enough to reverse one operation and to do it again: what it changed,
/// each with its value before and after.
public struct UndoRecord: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let operation: UndoOperation
    public let date: Date
    public let head: UndoChange<UndoHead>
    /// Local branches and tags by full name, with their targets (`nil` where
    /// absent). Includes the branches `HEAD` was on before and after, even
    /// when they did not move, so undo can check nothing moved them since.
    public let refs: [String: UndoChange<OID?>]
    /// Upstream configuration, by full branch name, where it changed.
    public let upstreams: [String: UndoChange<UndoUpstream>]
    public let working: UndoChange<UndoWorkingState>?
    public let stash: UndoChange<[UndoStashEntry]>?
    /// For a rename, the names before and after, so the branch's reflog and
    /// configuration move with it.
    public let rename: UndoChange<String>?

    public var title: String { operation.title }

    init(
        operation: UndoOperation, head: UndoChange<UndoHead>, refs: [String: UndoChange<OID?>],
        upstreams: [String: UndoChange<UndoUpstream>], working: UndoChange<UndoWorkingState>?,
        stash: UndoChange<[UndoStashEntry]>?, rename: UndoChange<String>?
    ) {
        id = UUID()
        date = Date()
        self.operation = operation
        self.head = head
        self.refs = refs
        self.upstreams = upstreams
        self.working = working
        self.stash = stash
        self.rename = rename
    }
}

/// Which way to apply a record.
public enum UndoDirection: Hashable, Sendable {
    case undo
    case redo

    /// The side the repository has to be on now.
    var from: UndoSide { self == .undo ? .after : .before }
    /// The side it is returned to.
    var to: UndoSide { self == .undo ? .before : .after }
}

enum UndoSide {
    case before
    case after
}

/// The state captured before an operation ran, kept until it finishes.
public struct UndoStart: Sendable {
    let operation: UndoOperation
    let checkpoint: Result<UndoCheckpoint, UndoError>
}

/// Everything a record compares, read in one go.
struct UndoCheckpoint: Sendable {
    var state: RepositoryState
    var head: UndoHead?
    var refs: [String: OID]
    var upstreams: [String: UndoUpstream]
    var working: UndoWorkingState?
    var stash: [UndoStashEntry]?
}

/// Whether an undo or redo can go ahead.
public enum UndoPreflight: Hashable, Sendable {
    case ready
    /// It can, but it rewrites history that has been pushed: say so first.
    case needsConfirmation(String)
}

/// Why an operation could not be recorded, or a record not applied.
public enum UndoError: Error, Hashable, Sendable, LocalizedError {
    /// Something other than the operation changed what it would restore.
    case changedSince(String)
    case operationInProgress(RepositoryState)
    /// An object the record needs has been removed, as by garbage collection.
    case objectsMissing
    case conflicts
    /// An untracked file is too big, or not a plain file, to keep a copy of.
    case cannotKeepCopy(path: String)
    case noWorkingDirectory

    public var errorDescription: String? {
        switch self {
        case .changedSince(let what):
            "\(what) Undoing now could lose that change, so nothing was done."
        case .operationInProgress(let state):
            "A \(state.operationName) is in progress. Continue or abort it first."
        case .objectsMissing:
            "The saved copy it needs is no longer in the repository, so it cannot be restored."
        case .conflicts:
            "Some files have conflicts. Resolve them first."
        case .cannotKeepCopy(let path):
            "“\(path)” is too large, or not a plain file, to keep a copy of."
        case .noWorkingDirectory:
            "This repository is bare: it has no working copy."
        }
    }
}

extension OID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let id = OID(hex: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an object name: \(hex)")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
