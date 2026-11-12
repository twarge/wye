import Foundation
import GitKit
import Observation
import WyeShared

/// What the app knows of each listed repository's status, wherever it
/// learned it: the repository list reading each one, an open window's
/// refresh, a background fetch. Published to `SharedStatusStore` for the
/// widgets as it changes.
@MainActor
@Observable
final class RepositoryStatusBoard {
    static let shared = RepositoryStatusBoard()

    private(set) var summaries: [UUID: RepositoryStatusSummary]
    /// Whether to write `SharedStatusStore`; off in tests.
    private let publishes: Bool
    private var pendingSave: Task<Void, Never>?

    init(publishes: Bool = true) {
        self.publishes = publishes
        let saved = publishes ? SharedStatusStore.load() : []
        summaries = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    func record(_ summary: RepositoryStatusSummary) {
        let old = summaries[summary.id]
        summaries[summary.id] = summary
        // A newer time alone is not worth a write; what it says is.
        if var old {
            old.updated = summary.updated
            if old == summary { return }
        }
        scheduleSave()
    }

    /// Forgets repositories no longer listed.
    func retain(_ ids: Set<UUID>) {
        let gone = summaries.keys.filter { !ids.contains($0) }
        if publishes { FinderStatusPublisher.retain(ids) }
        guard !gone.isEmpty else { return }
        for id in gone { summaries[id] = nil }
        scheduleSave()
    }

    /// Many updates in a row, as the list reads each repository, make one write.
    private func scheduleSave() {
        guard publishes else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let summaries = self.summaries.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            await Task.detached(priority: .utility) { SharedStatusStore.save(summaries) }.value
        }
    }
}

extension RepositoryStatusSummary {
    /// Reads a repository's status: its branch, how far it is from its
    /// upstream, and whether anything is uncommitted.
    static func read(from repository: Repository, id: UUID, name: String) async throws -> RepositoryStatusSummary {
        let snapshot = try await repository.snapshot()
        let entries = try await repository.status()
        let summary = RepositoryStatusSummary(snapshot: snapshot, hasUncommittedChanges: !entries.isEmpty, id: id, name: name)
        await FinderStatusPublisher.publish(
            id: id, name: name, root: repository.url, branch: summary.branch, entries: entries
        )
        return summary
    }

    init(snapshot: RepositorySnapshot, hasUncommittedChanges: Bool, id: UUID, name: String, updated: Date = .now) {
        let head = snapshot.branches.first { $0.isHead }
        let branch = snapshot.head.branchName.map { name in
            name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
        }
        self.init(
            id: id, name: name, branch: branch,
            ahead: head?.upstream?.ahead ?? 0, behind: head?.upstream?.behind ?? 0,
            hasUncommittedChanges: hasUncommittedChanges, updated: updated
        )
    }
}

extension RepositoryModel {
    /// Tells the board what this open repository shows now.
    func publishStatus() {
        guard let snapshot else { return }
        let summary = RepositoryStatusSummary(
            snapshot: snapshot, hasUncommittedChanges: !workingCopy.entries.isEmpty, id: id, name: name
        )
        RepositoryStatusBoard.shared.record(summary)
        FinderStatusPublisher.publish(
            id: id, name: name, root: repository.url, branch: summary.branch, entries: workingCopy.entries
        )
    }
}
