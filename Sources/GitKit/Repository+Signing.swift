import Clibgit2
import Foundation
import Synchronization

/// Signs the commits a repository makes, with an SSH key, as git does with
/// `gpg.format=ssh` and `commit.gpgSign=true`.
public struct CommitSigner: Hashable, Sendable {
    public var key: SSHPrivateKey

    public init(key: SSHPrivateKey) {
        self.key = key
    }

    /// The armored signature of a commit's bytes, for its `gpgsig` header.
    public func sign(_ content: Data) throws -> String {
        try SSHSignature.sign(content, with: key, namespace: SSHSignature.gitNamespace)
    }
}

/// The signer a repository's commits are made with, if any. A class, so
/// that libgit2's rebase can reach it through its callback's payload.
final class CommitSigning: Sendable {
    private let signer = Mutex<CommitSigner?>(nil)

    var current: CommitSigner? {
        get { signer.withLock { $0 } }
        set { signer.withLock { $0 = newValue } }
    }
}

/// What a commit's signature says.
public enum CommitSignatureStatus: Hashable, Sendable {
    case unsigned
    /// A good SSH signature by a key that is trusted as `principal`.
    case verified(principal: String, key: SSHPublicKey)
    /// A good SSH signature by a key nobody vouches for.
    case unknownKey(SSHPublicKey)
    /// The signature does not match the commit, or cannot be read.
    case invalid(reason: String)
    /// A GPG or X.509 signature, which the app has no way to check.
    case unverifiable(format: String)
}

/// How a commit made through `createCommit` moves `HEAD`, for its reflog line.
enum CommitReflog {
    case commit
    case amend
    case merge

    func message(summary: String, isInitial: Bool) -> String {
        switch self {
        case .commit: isInitial ? "commit (initial): \(summary)" : "commit: \(summary)"
        case .amend: "commit (amend): \(summary)"
        case .merge: "commit (merge): \(summary)"
        }
    }
}

extension Repository {
    // MARK: Signing commits

    /// Signs every commit this repository makes from now on with `signer`,
    /// or stops signing with `nil`: commits from the composer, amends,
    /// merges, cherry-picks, reverts and rebases.
    public nonisolated func setCommitSigner(_ signer: CommitSigner?) {
        signing.current = signer
    }

    public nonisolated var commitSigner: CommitSigner? {
        signing.current
    }

    /// Writes a commit and, when `updatesHead`, points `HEAD` at it, as
    /// `git_commit_create` does with `"HEAD"`, but signed when a signer is
    /// set. The one place commits that move `HEAD` are made, so that every
    /// kind of commit is signed alike.
    func createCommit(
        author: UnsafePointer<git_signature>,
        committer: UnsafePointer<git_signature>,
        message: String,
        tree: OpaquePointer?,
        parents: [OpaquePointer?],
        updatesHead: Bool = true,
        reflog: CommitReflog? = nil
    ) throws -> OID {
        var parents = parents
        guard let signer = signing.current else {
            var id = git_oid()
            try check(git_commit_create(
                &id, pointer, updatesHead ? "HEAD" : nil, author, committer, nil, message, tree, parents.count, &parents
            ))
            return OID(id)
        }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try check(git_commit_create_buffer(&buffer, pointer, author, committer, nil, message, tree, parents.count, &parents))
        let id = try writeSigned(buffer, with: signer)
        if updatesHead {
            let kind = reflog ?? (parents.count > 1 ? .merge : .commit)
            let summary = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            try pointHead(at: id, log: kind.message(summary: summary, isInitial: parents.isEmpty))
        }
        return id
    }

    /// Replaces `head`, the commit `HEAD` points at, with one that keeps its
    /// author and parents, as `git_commit_amend` does, but signed when a
    /// signer is set. `tree` and `message` default to the commit's own.
    func amendHead(
        _ head: OpaquePointer?, committer: UnsafePointer<git_signature>, message: String?, tree: OpaquePointer?
    ) throws -> OID {
        guard signing.current != nil else {
            var id = git_oid()
            try check(git_commit_amend(&id, head, "HEAD", nil, committer, nil, message, tree))
            return OID(id)
        }
        var parents: [OpaquePointer?] = []
        defer { parents.forEach { git_commit_free($0) } }
        for index in 0..<git_commit_parentcount(head) {
            var parent: OpaquePointer?
            try check(git_commit_parent(&parent, head, index))
            parents.append(parent)
        }
        var ownTree: OpaquePointer?
        if tree == nil { try check(git_commit_tree(&ownTree, head)) }
        defer { git_tree_free(ownTree) }
        let text = message ?? git_commit_message(head).map { String(cString: $0) } ?? ""
        return try createCommit(
            author: git_commit_author(head), committer: committer, message: text, tree: tree ?? ownTree,
            parents: parents, reflog: .amend
        )
    }

    /// Writes a commit buffer to the object database with its signature.
    private func writeSigned(_ buffer: git_buf, with signer: CommitSigner) throws -> OID {
        guard let content = buffer.ptr else { throw GitError(code: -1, message: "The commit could not be written.") }
        let data = Data(bytes: content, count: buffer.size)
        let signature = try signer.sign(data)
        var id = git_oid()
        try check(git_commit_create_with_signature(&id, pointer, content, signature, "gpgsig"))
        return OID(id)
    }

    /// Moves the branch `HEAD` is on, or `HEAD` itself when detached, to a
    /// commit, logging it as git logs a commit.
    private func pointHead(at id: OID, log: String) throws {
        var oid = id.raw
        var head: OpaquePointer?
        try check(git_reference_lookup(&head, pointer, "HEAD"))
        defer { git_reference_free(head) }
        // An unborn branch's name, or the branch HEAD is on; a detached
        // HEAD is moved itself.
        let target = git_reference_type(head) == GIT_REFERENCE_SYMBOLIC
            ? git_reference_symbolic_target(head).map { String(cString: $0) } : nil
        var reference: OpaquePointer?
        try check(git_reference_create(&reference, pointer, target ?? "HEAD", &oid, 1, log))
        git_reference_free(reference)
    }

    /// Makes libgit2's rebase sign the commits it makes, through its commit
    /// callback. The rebase code calls this on its options before starting
    /// or resuming a rebase; with no signer the callback lets libgit2 make
    /// the commit itself.
    func applyCommitSigning(to options: inout git_rebase_options) {
        options.payload = Unmanaged.passUnretained(signing).toOpaque()
        options.commit_create_cb = { out, author, committer, encoding, message, tree, count, parents, payload in
            guard let out, let tree, let payload else { return GIT_PASSTHROUGH.rawValue }
            let signing = Unmanaged<CommitSigning>.fromOpaque(payload).takeUnretainedValue()
            guard let signer = signing.current else { return GIT_PASSTHROUGH.rawValue }
            let repository = git_tree_owner(tree)
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            var code = git_commit_create_buffer(&buffer, repository, author, committer, encoding, message, tree, count, parents)
            guard code == 0, let content = buffer.ptr else { return code }
            guard let signature = try? signer.sign(Data(bytes: content, count: buffer.size)) else {
                // Refuses the commit; the rebase stops with libgit2's error.
                return GIT_EUSER.rawValue
            }
            code = git_commit_create_with_signature(out, repository, content, signature, "gpgsig")
            return code
        }
    }

    /// A signature for now, as `identity`, or as the configured identity
    /// when there is none. The caller frees it.
    func signatureNow(as identity: GitIdentity?) throws -> UnsafeMutablePointer<git_signature> {
        var signature: UnsafeMutablePointer<git_signature>?
        if let identity {
            try check(git_signature_now(&signature, identity.name, identity.email))
        } else if git_signature_default(&signature, pointer) != 0 {
            throw RepositoryError.identityNotConfigured
        }
        guard let signature else { throw RepositoryError.identityNotConfigured }
        return signature
    }

    // MARK: Verifying

    /// Checks a commit's signature. An SSH signature is verified, then its
    /// key is looked up among `trusted`; other kinds can only be named.
    public func signatureStatus(of id: OID, trusting trusted: [AllowedSigner]) throws -> CommitSignatureStatus {
        var signature = git_buf()
        var signedData = git_buf()
        defer {
            git_buf_dispose(&signature)
            git_buf_dispose(&signedData)
        }
        var oid = id.raw
        let code = git_commit_extract_signature(&signature, &signedData, pointer, &oid, nil)
        if code == GIT_ENOTFOUND.rawValue { return .unsigned }
        try check(code)
        let text = signature.ptr.map { String(cString: $0) } ?? ""
        guard SSHSignature.isSSHSignature(text) else {
            return .unverifiable(format: text.contains("BEGIN SIGNED MESSAGE") ? "X.509" : "GPG")
        }
        let message = signedData.ptr.map { Data(bytes: $0, count: signedData.size) } ?? Data()
        let verification: SSHSignature.Verification
        do {
            verification = try SSHSignature.verify(text, message: message)
        } catch {
            return .invalid(reason: error.localizedDescription)
        }
        guard verification.isValid else {
            return .invalid(reason: "The signature does not match the commit’s contents.")
        }
        if let signer = trusted.first(where: { $0.key == verification.publicKey }) {
            return .verified(principal: signer.principal, key: verification.publicKey)
        }
        return .unknownKey(verification.publicKey)
    }
}
