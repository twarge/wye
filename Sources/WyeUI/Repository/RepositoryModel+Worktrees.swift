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
    func removeWorktree(_ name: String, force: Bool, library: RepositoryLibrary) async {
        guard let old = worktree(named: name) else { return }
        let listed = library.bookmark(at: URL(filePath: old.path, directoryHint: .isDirectory))
        await perform { repository in
            let access = listed.flatMap { try? library.access(to: $0) }
            defer { withExtendedLifetime(access) {} }
            try await repository.removeWorktree(name, force: force)
            if let listed { library.remove(listed) }
            if self.selection == .worktree(name) {
                self.selection = .history
            }
        }
    }

    func pruneWorktrees() async {
        await perform { _ = try await $0.pruneWorktrees() }
    }
}
