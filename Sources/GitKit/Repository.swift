import Clibgit2
import Foundation

/// An open git repository.
///
/// libgit2 objects are not safe to share between threads, so the repository is
/// an actor: every operation runs in turn, off the main thread.
public actor Repository {
    /// The folder the repository was opened from.
    public nonisolated let url: URL
    public nonisolated let isBare: Bool

    private let handle: Handle
    var walks: [HistoryCursor: Walk] = [:]
    /// The key new commits are signed with, if any (`Repository+Signing.swift`).
    let signing = CommitSigning()

    /// Opens the repository at `url`: a working copy, or a bare repository.
    public init(at url: URL) throws {
        GitEnvironment.ensureInitialized()
        var pointer: OpaquePointer?
        // No searching upwards: a parent folder is outside what the user
        // picked, and outside the sandbox.
        try check(git_repository_open_ext(&pointer, url.path, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil))
        self.url = url
        self.isBare = git_repository_is_bare(pointer) != 0
        self.handle = Handle(pointer: pointer!)
    }

    /// Whether `url` is the top folder of a repository.
    public static func exists(at url: URL) -> Bool {
        GitEnvironment.ensureInitialized()
        return git_repository_open_ext(nil, url.path, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil) == 0
    }

    /// Creates an empty repository with a working copy at `url`.
    public static func create(at url: URL) throws -> Repository {
        GitEnvironment.ensureInitialized()
        var pointer: OpaquePointer?
        try check(git_repository_init(&pointer, url.path, 0))
        git_repository_free(pointer)
        return try Repository(at: url)
    }

    var pointer: OpaquePointer { handle.pointer }

    /// Reads several things in one turn: nothing else the repository is
    /// asked for comes between them, and the caller waits once for all of
    /// them, where a window would otherwise lay itself out again after each.
    public func read<Value: Sendable>(
        _ body: @Sendable (isolated Repository) throws -> Value
    ) rethrows -> Value {
        try body(self)
    }

    /// Owns the libgit2 repository, freeing it with the actor.
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer

        init(pointer: OpaquePointer) {
            self.pointer = pointer
        }

        deinit {
            git_repository_free(pointer)
        }
    }

    // MARK: Shared lookups

    func lookupCommit(_ id: OID) throws -> OpaquePointer {
        var oid = id.raw
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, pointer, &oid))
        return commit!
    }

    /// The commit `HEAD` points at, or `nil` on a branch with no commits. The
    /// caller frees it.
    func headCommit() throws -> OpaquePointer? {
        var reference: OpaquePointer?
        let code = git_repository_head(&reference, pointer)
        if code == GIT_EUNBORNBRANCH.rawValue || code == GIT_ENOTFOUND.rawValue { return nil }
        try check(code)
        defer { git_reference_free(reference) }
        var commit: OpaquePointer?
        try check(git_reference_peel(&commit, reference, GIT_OBJECT_COMMIT))
        return commit
    }

    func tree(of commit: OpaquePointer?) throws -> OpaquePointer? {
        guard let commit else { return nil }
        var tree: OpaquePointer?
        try check(git_commit_tree(&tree, commit))
        return tree
    }
}

extension Commit {
    init(_ commit: OpaquePointer) {
        let message = git_commit_body(commit).map { String(cString: $0) } ?? ""
        self.init(
            id: OID(git_commit_id(commit)),
            parentIDs: (0..<git_commit_parentcount(commit)).map { OID(git_commit_parent_id(commit, $0)) },
            treeID: OID(git_commit_tree_id(commit)),
            author: Signature(git_commit_author(commit).pointee),
            committer: Signature(git_commit_committer(commit).pointee),
            summary: git_commit_summary(commit).map { String(cString: $0) } ?? "",
            body: message.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

extension Signature {
    init(_ signature: git_signature) {
        self.init(
            name: signature.name.map { String(cString: $0) } ?? "",
            email: signature.email.map { String(cString: $0) } ?? "",
            date: Date(timeIntervalSince1970: TimeInterval(signature.when.time)),
            timeZone: TimeZone(secondsFromGMT: Int(signature.when.offset) * 60) ?? .gmt
        )
    }
}
