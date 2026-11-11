import Clibgit2
import Foundation

/// How a repository's branches stand against its main branch.
public struct BranchReview: Hashable, Sendable {
    /// The branch the others are measured against, by full reference name.
    public var base: String?
    /// The branches, by full reference name, whose every commit the base
    /// holds, as `git branch --merged <base>` lists them. The base itself
    /// is not among them.
    public var merged: Set<String>
    /// When each branch's tip was committed.
    public var tipDates: [String: Date]

    public init(base: String?, merged: Set<String> = [], tipDates: [String: Date] = [:]) {
        self.base = base
        self.merged = merged
        self.tipDates = tipDates
    }
}

extension Repository {
    /// The branch the repository's work is merged into, by full reference
    /// name: the branch `origin/HEAD` names (the local one when there is
    /// one, otherwise the remote branch), else `main`, else `master`, else
    /// the checked-out branch. `nil` when there is none of them.
    public func mainBranch() throws -> String? {
        var remoteHead: OpaquePointer?
        if git_reference_lookup(&remoteHead, pointer, "refs/remotes/origin/HEAD") == 0 {
            defer { git_reference_free(remoteHead) }
            if git_reference_type(remoteHead) == GIT_REFERENCE_SYMBOLIC,
               let target = git_reference_symbolic_target(remoteHead).map({ String(cString: $0) }),
               target.hasPrefix("refs/remotes/origin/") {
                let local = "refs/heads/" + target.dropFirst("refs/remotes/origin/".count)
                if referenceExists(local) { return local }
                if referenceExists(target) { return target }
            }
        }
        for name in ["refs/heads/main", "refs/heads/master"] where referenceExists(name) {
            return name
        }
        if case .branch(let name, _) = try head() { return name }
        return nil
    }

    /// Which of `branches`, by full reference name, are merged into `base`,
    /// and when each tip was committed. A branch that cannot be read is
    /// left out.
    public func reviewBranches(_ branches: [String], against base: String?) throws -> BranchReview {
        let baseID = base.flatMap { try? commitID(ofReference: $0) }
        var review = BranchReview(base: base)
        for branch in branches {
            guard let tip = try? commitID(ofReference: branch) else { continue }
            if let commit = try? lookupCommit(tip) {
                review.tipDates[branch] = Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))
                git_commit_free(commit)
            }
            guard let baseID, branch != base else { continue }
            if tip == baseID {
                review.merged.insert(branch)
                continue
            }
            var descendant = baseID.raw, ancestor = tip.raw
            if git_graph_descendant_of(pointer, &descendant, &ancestor) == 1 {
                review.merged.insert(branch)
            }
        }
        return review
    }

    private func referenceExists(_ name: String) -> Bool {
        var oid = git_oid()
        return git_reference_name_to_id(&oid, pointer, name) == 0
    }
}
