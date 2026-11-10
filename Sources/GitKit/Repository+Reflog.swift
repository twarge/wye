import Clibgit2
import Foundation

/// One move of a reference, as its reflog recorded it.
public struct ReflogEntry: Identifiable, Hashable, Sendable {
    /// Position in the reflog, `0` being the latest: `HEAD@{index}`.
    public let index: Int
    /// Where the reference pointed before; `nil` when this entry created it.
    public let oldID: OID?
    public let newID: OID
    /// What moved it, such as `commit: Fix the build` or `checkout: moving from main to topic`.
    public let message: String
    public let committer: Signature

    public var id: Int { index }
}

extension Repository {
    /// The reflog of a reference, latest first: `HEAD`, or a full name such
    /// as `refs/heads/main`. Empty when the reference has none.
    public func reflog(of reference: String = "HEAD") throws -> [ReflogEntry] {
        var reflog: OpaquePointer?
        try check(git_reflog_read(&reflog, pointer, reference))
        defer { git_reflog_free(reflog) }
        return (0..<git_reflog_entrycount(reflog)).compactMap { index in
            guard let entry = git_reflog_entry_byindex(reflog, index),
                  let new = git_reflog_entry_id_new(entry) else { return nil }
            let old = git_reflog_entry_id_old(entry).flatMap { git_oid_is_zero($0) != 0 ? nil : OID($0) }
            return ReflogEntry(
                index: index,
                oldID: old,
                newID: OID(new),
                message: git_reflog_entry_message(entry).map { String(cString: $0) } ?? "",
                committer: git_reflog_entry_committer(entry).map { Signature($0.pointee) }
                    ?? Signature(name: "", email: "", date: .distantPast)
            )
        }
    }
}
