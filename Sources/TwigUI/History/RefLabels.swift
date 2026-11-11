import GitKit

extension RefLabel {
    /// The badges each commit shows, from a snapshot's references. Pure, so
    /// it can be tested without a window.
    ///
    /// - `HEAD` gets no badge: its row is bold instead. Only a detached
    ///   `HEAD` keeps a small `.head` marker, since no branch says where it is.
    /// - A remote's own `HEAD` (`origin/HEAD`) only says which branch the
    ///   remote has checked out, so it is not shown.
    /// - A remote branch at the same commit as a local branch joins that
    ///   branch's badge, in `remotes`, when it is the branch's upstream or
    ///   has the same name on its remote (`origin/main` with `main`).
    ///   On different commits they stay apart.
    ///
    /// Badges come in the order: detached `HEAD`, local branches, tags,
    /// then the remote branches that stand alone.
    static func labels(in snapshot: RepositorySnapshot) -> [OID: [RefLabel]] {
        var labels: [OID: [RefLabel]] = [:]
        if case .detached(let target) = snapshot.head {
            labels[target, default: []].append(RefLabel(name: "HEAD", kind: .head))
        }

        let remoteBranches = snapshot.remotes.flatMap(\.branches).filter { $0.nameWithoutRemote != "HEAD" }
        // Remote branches by the commit they are at, so a local branch
        // looks only at its own commit's.
        var remotesAt: [OID: [Branch]] = [:]
        for branch in remoteBranches {
            remotesAt[branch.target, default: []].append(branch)
        }

        // Upstreams claim their remote branch first, so a remote branch that
        // one branch tracks and another merely shares a name with goes to
        // the one that tracks it.
        var joined: [String: [String]] = [:]
        var taken: Set<String> = []
        for branch in snapshot.branches {
            guard let upstream = branch.upstream?.name,
                  remotesAt[branch.target]?.contains(where: { $0.name == upstream }) == true,
                  !taken.contains(upstream) else { continue }
            joined[branch.id, default: []].append(upstream)
            taken.insert(upstream)
        }
        for branch in snapshot.branches {
            for remote in remotesAt[branch.target] ?? []
            where remote.nameWithoutRemote == branch.name && !taken.contains(remote.name) {
                joined[branch.id, default: []].append(remote.name)
                taken.insert(remote.name)
            }
        }

        for branch in snapshot.branches {
            labels[branch.target, default: []].append(
                RefLabel(name: branch.name, kind: .branch, remotes: joined[branch.id] ?? [])
            )
        }
        for tag in snapshot.tags {
            labels[tag.target, default: []].append(RefLabel(name: tag.name, kind: .tag))
        }
        for branch in remoteBranches where !taken.contains(branch.name) {
            labels[branch.target, default: []].append(RefLabel(name: branch.name, kind: .remote))
        }
        return labels
    }

    /// What the badge says aloud and in its tooltip.
    var spokenDescription: String {
        switch kind {
        case .head: "HEAD, detached at this commit"
        case .branch where remotes.isEmpty: "Branch \(name)"
        case .branch: "Branch \(name), the same as \(remotes.formatted(.list(type: .and)))"
        case .tag: "Tag \(name)"
        case .remote: "Remote branch \(name)"
        }
    }
}
