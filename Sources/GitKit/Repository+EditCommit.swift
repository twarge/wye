import Clibgit2
import Foundation

/// Why an earlier commit cannot be edited.
public enum EditCommitError: Error, Hashable, Sendable, LocalizedError {
    case notInHistory
    case emptyMessage
    case nothingChanged

    public var errorDescription: String? {
        switch self {
        case .notInHistory: "That commit is not part of the current branch’s history, so editing it would not change the branch."
        case .emptyMessage: "A commit message cannot be empty."
        case .nothingChanged: "The message and author are as they were."
        }
    }
}

extension Repository {
    /// Gives an earlier commit of the current branch a new message, author,
    /// or both, and makes new copies of every commit after it to sit on the
    /// new one, as an interactive rebase with that commit reworded or
    /// amended would. Every commit keeps its files, so nothing can conflict
    /// and the index and working tree are left alone. Merge commits after it
    /// are copied with their other parents, rather than flattened.
    ///
    /// Returns the branch's new tip. The old one stays in the reflog and in
    /// `ORIG_HEAD`.
    @discardableResult
    public func editCommit(_ target: OID, message: String? = nil, author: Signature? = nil) throws -> OID {
        try requireNoOperation()
        if let message, message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EditCommitError.emptyMessage
        }
        let committer = try branchingSignature()
        defer { git_signature_free(committer) }
        guard let head = try head().target else { throw EditCommitError.notInHistory }
        var tip = head.raw
        var base = target.raw
        guard head == target || git_graph_descendant_of(pointer, &tip, &base) == 1 else {
            throw EditCommitError.notInHistory
        }

        let original = try lookupCommit(target)
        defer { git_commit_free(original) }
        let originalMessage = git_commit_message(original).map { String(cString: $0) } ?? ""
        let newMessage = message.map(Self.committedMessage) ?? originalMessage
        let oldAuthor = Signature(git_commit_author(original).pointee)
        if newMessage == originalMessage && (author == nil || author == oldAuthor) {
            throw EditCommitError.nothingChanged
        }

        // The commits that can lead back to the target, oldest first.
        var walker: OpaquePointer?
        try check(git_revwalk_new(&walker, pointer))
        defer { git_revwalk_free(walker) }
        git_revwalk_sorting(walker, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_REVERSE.rawValue)
        try check(git_revwalk_push(walker, &tip))
        for index in 0..<git_commit_parentcount(original) {
            var parent = git_commit_parent_id(original, index).pointee
            try check(git_revwalk_hide(walker, &parent))
        }

        var replaced: [OID: OID] = [:]
        var id = git_oid()
        while git_revwalk_next(&id, walker) == 0 {
            let oldID = OID(id)
            let commit = try lookupCommit(oldID)
            defer { git_commit_free(commit) }
            let parentIDs = (0..<git_commit_parentcount(commit)).map { OID(git_commit_parent_id(commit, $0)) }
            let newParents = parentIDs.map { replaced[$0] ?? $0 }
            // A commit from a side line that does not include the target stays as it is.
            guard oldID == target || newParents != parentIDs else { continue }

            var parents: [OpaquePointer?] = []
            defer { parents.forEach { git_commit_free($0) } }
            for parent in newParents { parents.append(try lookupCommit(parent)) }
            var tree: OpaquePointer?
            try check(git_commit_tree(&tree, commit))
            defer { git_tree_free(tree) }
            let text = oldID == target ? newMessage : git_commit_message(commit).map { String(cString: $0) } ?? ""

            if oldID == target, let author {
                let signature = try makeSignature(author)
                defer { git_signature_free(signature) }
                replaced[oldID] = try createCommit(
                    author: signature, committer: committer, message: text, tree: tree, parents: parents, updatesHead: false
                )
            } else {
                replaced[oldID] = try createCommit(
                    author: git_commit_author(commit), committer: committer, message: text, tree: tree,
                    parents: parents, updatesHead: false
                )
            }
        }

        let newHead = replaced[head] ?? head
        try writeGitFile("ORIG_HEAD", head.hex + "\n")
        let verb = message != nil && newMessage != originalMessage ? "reword" : "edit"
        let subject = newMessage.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        try moveHeadTarget(to: newHead, log: "rebase (\(verb)): \(subject)")
        return newHead
    }

    /// How many commits `tip` has that `base` does not: those after `base`
    /// when it is an ancestor.
    public func commitCount(from base: OID, to tip: OID) throws -> Int {
        var ahead = 0
        var behind = 0
        var local = tip.raw
        var upstream = base.raw
        try check(git_graph_ahead_behind(&ahead, &behind, pointer, &local, &upstream))
        return ahead
    }

    /// A libgit2 signature for `signature`. The caller frees it.
    func makeSignature(_ signature: Signature) throws -> UnsafeMutablePointer<git_signature> {
        var result: UnsafeMutablePointer<git_signature>?
        let seconds = git_time_t(signature.date.timeIntervalSince1970.rounded(.down))
        let offset = Int32(signature.timeZone.secondsFromGMT(for: signature.date) / 60)
        try check(git_signature_new(&result, signature.name, signature.email, seconds, offset))
        guard let result else { throw RepositoryError.identityNotConfigured }
        return result
    }
}
