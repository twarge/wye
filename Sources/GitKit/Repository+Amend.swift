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
    @discardableResult
    public func amend(message: String) throws -> OID {
        let state = RepositoryState(git_repository_state(pointer))
        guard state == .clean else { throw WorkingCopyError.operationUnderWay(state) }
        guard let head = try headCommit() else { throw WorkingCopyError.nothingToAmend }
        defer { git_commit_free(head) }

        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0 else {
            throw RepositoryError.identityNotConfigured
        }
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
        var id = git_oid()
        try check(git_commit_amend(&id, head, "HEAD", nil, signature, nil, text, tree))
        return OID(id)
    }
}
