import Foundation
import GitKit
import WyeShared

/// Tells the Finder extension, on macOS, which files of each listed
/// repository are changed, so it can badge them. Written whenever Wye reads
/// a repository's status anyway; only when it differs from what was last
/// written.
@MainActor
enum FinderStatusPublisher {
    private static var published: [UUID: FinderRepositoryStatus] = [:]

    /// The badge of one changed file.
    nonisolated static func badge(for entry: StatusEntry) -> FinderBadge {
        if entry.isConflicted { return .conflicted }
        switch entry.unstaged {
        case .untracked?: return .untracked
        case .some: return .modified
        case nil: return .staged
        }
    }

    nonisolated static func status(
        id: UUID, name: String, root: URL, branch: String?, entries: [StatusEntry]
    ) -> FinderRepositoryStatus {
        var badges: [String: FinderBadge] = [:]
        for entry in entries.prefix(FinderRepositoryStatus.limit) {
            badges[entry.path] = badge(for: entry)
        }
        return FinderRepositoryStatus(
            id: id, name: name, root: root.standardizedFileURL.path(percentEncoded: false), branch: branch, badges: badges
        )
    }

    static func publish(id: UUID, name: String, root: URL, branch: String?, entries: [StatusEntry]) {
        #if os(macOS)
        let status = status(id: id, name: name, root: root, branch: branch, entries: entries)
        guard published[id] != status else { return }
        published[id] = status
        Task.detached(priority: .utility) { FinderStatusStore.save(status) }
        #endif
    }

    /// Forgets repositories no longer listed.
    static func retain(_ ids: Set<UUID>) {
        #if os(macOS)
        published = published.filter { ids.contains($0.key) }
        Task.detached(priority: .utility) { FinderStatusStore.retain(ids) }
        #endif
    }
}
