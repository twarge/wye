import Clibgit2
import Foundation

/// What became of the tags a branch push took along.
///
/// Tags go as `git push --tags` sends them: every local tag, never forced.
/// One the remote already has at the same object is left as it is; one it
/// has at another object is not overwritten but turned down, and so is one
/// the remote itself refuses. Neither stops the branch from being pushed.
public struct PushedTags: Hashable, Sendable {
    /// A tag that did not reach the remote, by short name, and why.
    public struct Rejection: Hashable, Sendable {
        public var tag: String
        public var reason: String

        public init(tag: String, reason: String) {
            self.tag = tag
            self.reason = reason
        }
    }

    /// Tags, by short name, that the remote did not have and now does.
    public var pushed: [String]
    public var rejected: [Rejection]

    public init(pushed: [String], rejected: [Rejection]) {
        self.pushed = pushed
        self.rejected = rejected
    }

    /// Why a tag is turned down when the remote has it elsewhere.
    public static let elsewhereReason = "the remote already has it on another commit"
}

extension Repository {
    /// Pushes a branch's refspec with every local tag, in one push.
    ///
    /// libgit2 sends every reference it is given, and git's own refusal to
    /// move a tag is left to the caller, so tags the remote has elsewhere
    /// are found in the negotiation. The negotiation cannot drop them from
    /// the push, so it stops it, and the push goes again without them: a
    /// second connection, only when there are such tags.
    func pushWithAllTags(
        _ branchRefspec: String, to remoteName: String, leases: [String: OID?], session: RemoteSession
    ) throws -> PushedTags {
        var targets: [String: OID] = [:]
        for name in try referenceNames(matching: "refs/tags/*") {
            var oid = git_oid()
            try check(git_reference_name_to_id(&oid, pointer, name))
            targets[name] = OID(oid)
        }
        var elsewhere: [String] = []
        while true {
            let tags = targets.filter { !elsewhere.contains($0.key) }
            do {
                let refused = try pushReferences(
                    [branchRefspec] + tags.keys.sorted().map { "\($0):\($0)" }, to: remoteName, leases: leases,
                    protectedTags: tags, tagsAlong: true, session: session
                )
                let refusedNames = Set(refused.map(\.reference))
                let rejected = elsewhere.map { PushedTags.Rejection(tag: Self.tagName($0), reason: PushedTags.elsewhereReason) }
                    + refused.map { PushedTags.Rejection(tag: Self.tagName($0.reference), reason: $0.reason) }
                return PushedTags(
                    pushed: session.tagUpdates.subtracting(refusedNames).sorted().map(Self.tagName),
                    rejected: rejected.sorted { $0.tag < $1.tag }
                )
            } catch RemoteError.tagExistsOnRemote where !session.tagConflicts.isEmpty && !session.isCancelled {
                // Each round leaves out at least one more tag, so this ends.
                elsewhere += session.tagConflicts
            }
        }
    }

    private static func tagName(_ reference: String) -> String {
        reference.hasPrefix("refs/tags/") ? String(reference.dropFirst("refs/tags/".count)) : reference
    }
}
