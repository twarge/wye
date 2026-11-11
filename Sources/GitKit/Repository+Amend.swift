import Clibgit2
import Foundation

extension Repository {
    /// The full message of the commit `HEAD` points at, or `nil` before the
    /// first commit.
    public func lastCommitMessage() throws -> String? {
        guard let head = try headCommit() else { return nil }
        defer { git_commit_free(head) }
        return git_commit_message(head).map { String(cString: $0) }
    }

    /// Replaces the commit `HEAD` points at with one that has the index as
    /// its content and `message` as its message. The author and parents stay;
    /// the committer becomes the current identity, as with git's own amend.
    ///
    /// - Parameter identity: The committer; `nil` for the configured identity.
    @discardableResult
    public func amend(message: String, as identity: GitIdentity? = nil) throws -> OID {
        let state = RepositoryState(git_repository_state(pointer))
        guard state == .clean else { throw WorkingCopyError.operationUnderWay(state) }
        guard let head = try headCommit() else { throw WorkingCopyError.nothingToAmend }
        defer { git_commit_free(head) }

        let signature = try signatureNow(as: identity)
        defer { git_signature_free(signature) }

        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))
        var treeID = git_oid()
        try check(git_index_write_tree(&treeID, index))
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &treeID))
        defer { git_tree_free(tree) }

        let text = message.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        return try amendHead(head, committer: signature, message: text, tree: tree)
    }
}

/// Which kind of commit `commitFixup` makes, as `git commit --fixup` and
/// `--squash` name them.
public enum FixupKind: String, Hashable, Sendable {
    /// `fixup! <subject>`: its changes join the commit, its message is dropped.
    case fixup
    /// `squash! <subject>`: its changes and message join the commit.
    case squash

    /// The commit's subject: `fixup! ` or `squash! ` and the target's subject.
    public func subject(for target: String) -> String {
        "\(rawValue)! \(target)"
    }
}

extension Repository {
    /// Commits the staged changes as a `fixup!` or `squash!` commit aimed
    /// at an earlier commit, as `git commit --fixup` and `--squash` do, for
    /// an autosquashing rebase to meld in later. `details` is the rest of a
    /// squash's message.
    @discardableResult
    public func commitFixup(_ kind: FixupKind, for target: OID, details: String = "") throws -> OID {
        guard try status().contains(where: { $0.staged != nil }) else { throw FixupError.nothingStaged }
        let subject = kind.subject(for: try commit(target).summary)
        let body = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return try commit(message: body.isEmpty ? subject : "\(subject)\n\n\(body)")
    }
}

public enum FixupError: Error, Hashable, Sendable, LocalizedError {
    case nothingStaged

    public var errorDescription: String? {
        "Nothing is staged. Stage the changes that belong in the earlier commit first."
    }
}
