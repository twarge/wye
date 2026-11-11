import Foundation
import GitKit

/// What the context menus do that is not a plain call into another area:
/// snapshots, branching from stashes, pruning, pushing a commit, force
/// pushing a branch other than the current one, and the branch layout.
extension RepositoryModel {
    /// Whether a merge, rebase or the like has to be finished first.
    var isBusy: Bool {
        (snapshot?.state ?? .clean) != .clean
    }

    // MARK: Snapshots and stashes

    func saveSnapshot(message: String) async {
        await perform(.snapshot) { try await $0.saveSnapshot(message: message) }
    }

    func createBranch(fromStash stash: Stash, named name: String) async {
        await perform(.branchFromStash) { repository in
            let branch = try await repository.createBranch(fromStash: stash, named: name)
            self.selection = .branch(branch)
        }
        if selectedStash == stash.id, snapshot?.stashes.contains(where: { $0.id == stash.id }) != true {
            selectedStash = nil
        }
    }

    /// Writes a stash's changes as a patch and asks where to save it.
    func exportPatch(of stash: Stash) async {
        do {
            let text = try await repository.patch(ofStash: stash)
            history.requests.patchExport = PatchExport(
                document: PatchDocument(text: text), fileName: "stash-\(stash.index)-\(stash.id.abbreviated()).patch"
            )
        } catch {
            self.error = PresentedError(error)
        }
    }

    // MARK: Branches

    /// Makes a local branch tracking a remote branch, by full name, under
    /// `name`, and checks it out if asked.
    func trackRemoteBranch(_ id: String, named name: String, checkOut: Bool) async {
        await perform(checkOut ? .checkout : .createBranch) { repository in
            let local = try await repository.createTrackingBranch(for: id, named: name)
            if checkOut {
                try await self.withAutostash("Check Out") { try $0.checkOut(branch: local) }
            }
            self.selection = .branch(local)
        }
    }

    /// Selects a commit in the full history, whatever the sidebar shows.
    func revealInFullHistory(_ id: OID) async {
        selection = .history
        await revealInHistory(id)
    }

    /// The commit a branch, remote branch or tag, by full name, points at.
    func target(of reference: String) -> OID? {
        snapshot?.branchingTarget(of: reference)
    }

    // MARK: Remotes

    /// Removes the remote branches the remote no longer has, without
    /// fetching, and says how many went.
    func pruneRemote(_ name: String) async {
        await runRemote("Pruning “\(name)”") { repository, transfer, _ in
            let pruned = try await repository.pruneRemote(name, credentials: CredentialStore.shared, transfer: transfer)
            self.remotes.notice = OperationNotice(
                title: pruned.isEmpty ? "Nothing to Prune" : "Pruned “\(name)”",
                message: pruned.isEmpty
                    ? "Every remote branch of “\(name)” is still on the remote."
                    : "Removed \(pruned.map { "“\(Self.displayName(ofReference: $0))”" }.joined(separator: ", ")), "
                        + "which \(pruned.count == 1 ? "is" : "are") gone from the remote. Local branches are kept."
            )
        }
    }

    /// Pushes a commit to a branch of a remote, forced with a lease when
    /// `force` is set.
    func push(commit: OID, to remote: String, as branch: String, force: Bool) async {
        await runRemote(force ? "Force Pushing" : "Pushing") { repository, transfer, _ in
            try await repository.push(
                commit: commit, to: remote, as: branch, force: force, credentials: CredentialStore.shared, transfer: transfer
            )
        }
    }

    /// Force pushes a local branch, by full name, to its upstream, refusing
    /// if the remote branch moved since the last fetch.
    func forcePush(branch id: String) async {
        guard let upstream = snapshot?.branches.first(where: { $0.id == id })?.upstream else { return }
        let (remote, name) = remoteParts(of: "refs/remotes/" + upstream.name)
        await runRemote("Force Pushing") { repository, transfer, _ in
            try await repository.push(
                branch: id, to: remote, as: name, force: true, credentials: CredentialStore.shared, transfer: transfer
            )
        }
    }

    // MARK: Branch layout

    /// The sidebar's branches: pinned, listed and archived, with their marks.
    func branchListing(staleMonths: Int, autoArchiveMonths: Int) -> BranchListing {
        BranchListing(
            branches: snapshot?.branches ?? [], state: interface.stored, review: interface.review,
            staleMonths: staleMonths, autoArchiveMonths: autoArchiveMonths
        )
    }

    /// Works out which branches are merged into the main branch and how
    /// old each is, once for each set of branches, off the main thread.
    /// The marks are a hint: if it fails, they are left off.
    func updateBranchReview() async {
        guard let snapshot, interface.needsReview(of: snapshot) else { return }
        let repository = repository
        let branches = snapshot.branches.map(\.id)
        guard let base = try? await repository.mainBranch(),
              let review = try? await repository.reviewBranches(branches, against: base) else {
            interface.take(BranchReview(base: nil), for: snapshot)
            return
        }
        // Another refresh may have come in meanwhile; its own review follows.
        guard self.snapshot == snapshot else { return }
        interface.take(review, for: snapshot)
    }
}
