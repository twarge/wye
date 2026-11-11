import Foundation
import GitKit
import Observation

/// The reflog being shown: where `HEAD` or a branch has pointed, latest first.
@MainActor
@Observable
final class ReflogModel {
    /// `HEAD`, or a branch's full reference name.
    var reference = "HEAD"
    /// The selected entry's index.
    var selection: Int?
    private(set) var entries: [ReflogEntry] = []
    private(set) var isLoaded = false

    private let repository: Repository

    init(repository: Repository) {
        self.repository = repository
    }

    /// The commit the selected entry moved the reference to.
    var selectedCommit: OID? {
        selection.flatMap { index in entries.first { $0.index == index }?.newID }
    }

    func load() async throws {
        let reference = reference
        let entries = try await repository.reflog(of: reference)
        guard reference == self.reference else { return }
        // Keep the selection on the same move when new entries arrive above it.
        if let selection, let selected = self.entries.first(where: { $0.index == selection }) {
            self.selection = entries.first { $0.newID == selected.newID && $0.message == selected.message
                && $0.committer.date == selected.committer.date }?.index
        }
        self.entries = entries
        isLoaded = true
    }
}
