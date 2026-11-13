import Foundation
import GitKit

extension RepositoryModel {
    func worktree(named name: String) -> Worktree? {
        snapshot?.worktrees.first { $0.name == name }
    }

    /// Linked worktrees are worth a sidebar section; the main one alone is
    /// just this repository.
    var hasLinkedWorktrees: Bool {
        snapshot?.worktrees.contains { !$0.isMain } == true
    }

    /// The worktree other than this one that has a local branch, by full
    /// reference name, checked out.
    func worktree(holding branch: String) -> Worktree? {
        snapshot?.worktrees.first { !$0.isCurrent && $0.head?.branchName == branch }
    }

    /// Whether a local branch can be deleted from here: not the one checked
    /// out, and not one the main worktree has. One a linked worktree has can
    /// go once that worktree is removed, which deleting it offers.
    func canDelete(_ branch: Branch) -> Bool {
        guard !branch.isHead else { return false }
        guard branch.worktreePath != nil else { return true }
        return worktree(holding: branch.id)?.isMain == false
    }

    /// How many files differ in a worktree, changed or untracked; `nil` when
    /// its folder is gone or cannot be read.
    func changeCount(in worktree: Worktree, library: RepositoryLibrary) async -> Int? {
        guard !worktree.isMissing else { return nil }
        let url = URL(filePath: worktree.path, directoryHint: .isDirectory)
        let access = library.bookmark(at: url).flatMap { try? library.access(to: $0) }
        defer { withExtendedLifetime(access) {} }
        guard let repository = try? Repository(at: url) else { return nil }
        return (try? await repository.status())?.count
    }

    /// Why a linked worktree cannot be removed from here, in a sentence, or
    /// `nil` when it can.
    func removalObstacle(for worktree: Worktree, library: RepositoryLibrary) -> String? {
        if worktree.isMain {
            return "The main worktree holds the repository itself, so it can’t be removed."
        }
        if worktree.isCurrent {
            return "This window shows “\(worktree.displayName)”, so it can’t be removed from here."
        }
        if worktree.isLocked {
            return "“\(worktree.displayName)” is locked\(worktree.lockReason.map { ": \($0)" } ?? ""). Unlock it to remove it."
        }
        if !worktree.isReachable, library.bookmark(at: URL(filePath: worktree.path, directoryHint: .isDirectory)) == nil {
            return "Wye has no access to the folder of “\(worktree.displayName)”. Open the worktree to give Wye access."
        }
        return nil
    }

    /// Adds a worktree in a new folder named `folderName` inside `parent`
    /// (picked by the user on macOS, which grants access to it; Documents
    /// on iOS), and lists it in the library. Returns its bookmark, to open.
    @discardableResult
    func addWorktree(
        named folderName: String, in parent: URL, target: WorktreeTarget, library: RepositoryLibrary, open: Bool
    ) async -> RepositoryBookmark? {
        var added: RepositoryBookmark?
        await perform { repository in
            let isScoped = parent.startAccessingSecurityScopedResource()
            defer {
                if isScoped { parent.stopAccessingSecurityScopedResource() }
            }
            let folder = parent.appending(path: folderName, directoryHint: .isDirectory)
            let worktree = try await repository.addWorktree(at: folder, target: target)
            added = try library.addWorktree(at: folder, main: self.bookmark)
            self.selection = .worktree(worktree.name)
            if open {
                self.nested.opening = .worktree(worktree.name)
            }
        }
        return added
    }

    func lockWorktree(_ name: String, reason: String) async {
        await perform { try await $0.lockWorktree(name, reason: reason) }
    }

    func unlockWorktree(_ name: String) async {
        await perform { try await $0.unlockWorktree(name) }
    }

    /// Moves a worktree to a folder named `folderName` in `parent`, and
    /// follows it in the library.
    func moveWorktree(_ name: String, into parent: URL, folderName: String, library: RepositoryLibrary) async {
        guard let old = worktree(named: name) else { return }
        let listed = library.bookmark(at: URL(filePath: old.path, directoryHint: .isDirectory))
        await perform { repository in
            // The worktree's own folder may be reachable only through its bookmark.
            let access = listed.flatMap { try? library.access(to: $0) }
            let isScoped = parent.startAccessingSecurityScopedResource()
            defer {
                if isScoped { parent.stopAccessingSecurityScopedResource() }
                withExtendedLifetime(access) {}
            }
            let destination = parent.appending(path: folderName, directoryHint: .isDirectory)
            try await repository.moveWorktree(name, to: destination)
            if let listed {
                library.relocate(listed, to: destination, parent: self.bookmark)
            }
        }
    }

    /// Removes a worktree's folder and entry, and forgets it in the library.
    /// Returns whether it was removed.
    @discardableResult
    func removeWorktree(_ name: String, force: Bool, library: RepositoryLibrary) async -> Bool {
        guard let old = worktree(named: name) else { return false }
        let listed = library.bookmark(at: URL(filePath: old.path, directoryHint: .isDirectory))
        var isRemoved = false
        await perform { repository in
            let access = listed.flatMap { try? library.access(to: $0) }
            defer { withExtendedLifetime(access) {} }
            try await repository.removeWorktree(name, force: force)
            isRemoved = true
            if let listed { library.remove(listed) }
            if self.selection == .worktree(name) {
                self.selection = .history
            }
        }
        return isRemoved
    }

    /// Removes a worktree, then deletes the local branch it had checked
    /// out, which git allows only once no worktree has it. The branch goes
    /// only if the worktree went.
    func removeWorktree(
        _ name: String, force: Bool, library: RepositoryLibrary, deletingBranch branch: String, forceBranch: Bool
    ) async {
        guard await removeWorktree(name, force: force, library: library) else { return }
        await deleteBranch(branch, force: forceBranch)
    }

    func pruneWorktrees() async {
        await perform { _ = try await $0.pruneWorktrees() }
    }
}
