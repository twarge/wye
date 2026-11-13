import Clibgit2
import Foundation

extension Repository {
    /// Reads the references, stashes, submodules and worktrees.
    ///
    /// - Parameter scanningSubmodules: Whether to look through each
    ///   submodule's working tree for changes, which takes as long as its
    ///   status does. Without it a submodule says only which commit it is
    ///   at: enough for a window to open with, ahead of the full reading.
    public func snapshot(scanningSubmodules: Bool = true) throws -> RepositorySnapshot {
        let head = try head()
        var branches: [Branch] = []
        var remoteBranches: [Branch] = []
        var tags: [Tag] = []

        var iterator: OpaquePointer?
        try check(git_reference_iterator_new(&iterator, pointer))
        defer { git_reference_iterator_free(iterator) }
        var reference: OpaquePointer?
        while git_reference_next(&reference, iterator) == 0 {
            defer { git_reference_free(reference) }
            guard let reference, let target = commitID(of: reference) else { continue }
            let fullName = String(cString: git_reference_name(reference))
            let name = String(cString: git_reference_shorthand(reference))
            if git_reference_is_branch(reference) != 0 {
                branches.append(Branch(
                    id: fullName, name: name, target: target, isRemote: false,
                    isHead: head.branchName == fullName, upstream: upstream(of: reference, at: target)
                ))
            } else if git_reference_is_remote(reference) != 0 {
                remoteBranches.append(Branch(
                    id: fullName, name: name, target: target, isRemote: true, isHead: false, upstream: nil
                ))
            } else if git_reference_is_tag(reference) != 0 {
                // An annotated tag points at a tag object, not at the commit.
                let direct = git_reference_target(reference).map { OID($0) }
                tags.append(Tag(id: fullName, name: name, target: target, isAnnotated: direct != target))
            }
        }

        let worktreeList = (try? worktrees()) ?? []
        // A branch checked out in another worktree is that worktree's to move.
        let elsewhere = Dictionary(
            worktreeList.filter { !$0.isCurrent }.compactMap { tree -> (String, String)? in
                tree.head?.branchName.map { ($0, tree.path) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        for index in branches.indices {
            branches[index].worktreePath = elsewhere[branches[index].id]
        }

        return RepositorySnapshot(
            head: head,
            state: RepositoryState(git_repository_state(pointer)),
            branches: branches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            remotes: try remotes(with: remoteBranches),
            tags: tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending },
            stashes: try stashes(),
            submodules: (try? submodules(scanningWorkingTrees: scanningSubmodules)) ?? [],
            worktrees: worktreeList
        )
    }

    public func head() throws -> Head {
        var reference: OpaquePointer?
        let code = git_repository_head(&reference, pointer)
        if code == GIT_EUNBORNBRANCH.rawValue {
            var symbolic: OpaquePointer?
            try check(git_reference_lookup(&symbolic, pointer, "HEAD"))
            defer { git_reference_free(symbolic) }
            let name = git_reference_symbolic_target(symbolic).map { String(cString: $0) }
            return .unborn(name: name ?? "refs/heads/main")
        }
        try check(code)
        defer { git_reference_free(reference) }
        guard let target = commitID(of: reference!) else {
            throw GitError(code: GIT_ENOTFOUND.rawValue, message: "HEAD does not point at a commit.")
        }
        if git_repository_head_detached(pointer) != 0 {
            return .detached(target)
        }
        return .branch(name: String(cString: git_reference_name(reference)), target: target)
    }

    /// The commit a reference leads to, through any tag objects.
    private func commitID(of reference: OpaquePointer) -> OID? {
        var object: OpaquePointer?
        guard git_reference_peel(&object, reference, GIT_OBJECT_COMMIT) == 0 else { return nil }
        defer { git_object_free(object) }
        return OID(git_object_id(object))
    }

    private func upstream(of branch: OpaquePointer, at target: OID) -> Branch.Upstream? {
        var upstream: OpaquePointer?
        guard git_branch_upstream(&upstream, branch) == 0, let upstream else { return nil }
        defer { git_reference_free(upstream) }
        guard let upstreamTarget = commitID(of: upstream) else { return nil }
        var ahead = 0, behind = 0
        var local = target.raw, remote = upstreamTarget.raw
        _ = git_graph_ahead_behind(&ahead, &behind, pointer, &local, &remote)
        return Branch.Upstream(
            name: String(cString: git_reference_shorthand(upstream)), ahead: ahead, behind: behind
        )
    }

    private func remotes(with branches: [Branch]) throws -> [Remote] {
        var names = git_strarray()
        try check(git_remote_list(&names, pointer))
        defer { git_strarray_dispose(&names) }
        return strings(in: names).map { name in
            var remote: OpaquePointer?
            let url = git_remote_lookup(&remote, pointer, name) == 0
                ? git_remote_url(remote).map { String(cString: $0) } : nil
            git_remote_free(remote)
            return Remote(
                name: name,
                url: url,
                branches: branches
                    .filter { $0.name.hasPrefix(name + "/") }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            )
        }
    }

    private func stashes() throws -> [Stash] {
        let collected = Collector<(index: Int, message: String, id: OID)>()
        try check(git_stash_foreach(pointer, { index, message, id, payload in
            guard let id, let payload else { return 0 }
            let collected = Unmanaged<Collector<(index: Int, message: String, id: OID)>>
                .fromOpaque(payload).takeUnretainedValue()
            collected.items.append((index, message.map { String(cString: $0) } ?? "", OID(id)))
            return 0
        }, Unmanaged.passUnretained(collected).toOpaque()))

        return collected.items.compactMap { item in
            guard let commit = try? lookupCommit(item.id) else { return nil }
            defer { git_commit_free(commit) }
            return Stash(
                id: item.id, index: item.index, message: item.message,
                date: Signature(git_commit_committer(commit).pointee).date
            )
        }
    }

    func strings(in array: git_strarray) -> [String] {
        (0..<array.count).compactMap { array.strings[$0].map { String(cString: $0) } }
    }
}

/// Gathers values from a C callback, which cannot capture Swift state.
final class Collector<Item> {
    var items: [Item] = []
}

extension RepositoryState {
    init(_ state: Int32) {
        switch git_repository_state_t(UInt32(state)) {
        case GIT_REPOSITORY_STATE_MERGE: self = .merging
        case GIT_REPOSITORY_STATE_REVERT, GIT_REPOSITORY_STATE_REVERT_SEQUENCE: self = .reverting
        case GIT_REPOSITORY_STATE_CHERRYPICK, GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE: self = .cherryPicking
        case GIT_REPOSITORY_STATE_BISECT: self = .bisecting
        case GIT_REPOSITORY_STATE_REBASE, GIT_REPOSITORY_STATE_REBASE_INTERACTIVE,
             GIT_REPOSITORY_STATE_REBASE_MERGE:
            self = .rebasing
        case GIT_REPOSITORY_STATE_APPLY_MAILBOX, GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE:
            self = .applyingMailbox
        default: self = .clean
        }
    }
}
