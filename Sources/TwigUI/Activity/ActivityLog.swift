import Foundation
import GitKit
import Observation

/// One operation Twig ran, for the activity log.
struct ActivityEntry: Identifiable, Hashable, Sendable {
    enum Outcome: Hashable, Sendable {
        case running
        case succeeded
        case cancelled
        /// What went wrong, as the alert said it.
        case failed(String)
    }

    let id: UUID
    var title: String
    /// The repository's name, or `nil` for one not yet in the list (a clone).
    var repository: String?
    var started: Date
    var finished: Date?
    var outcome: Outcome
    /// The last progress a network operation reported: objects and bytes.
    var transfer: TransferProgress?
    /// Run by Twig itself, such as a scheduled fetch, rather than asked for.
    var isBackground: Bool

    var duration: TimeInterval? {
        finished.map { $0.timeIntervalSince(started) }
    }
}

/// What the operation being run is called, for the activity log.
enum ActivityContext {
    /// The title `RepositoryModel.perform` logs its operation under. Set by
    /// callers that know what they are doing, such as an undoable operation.
    @TaskLocal static var operationTitle: String?
}

/// Every operation the app ran this session, across all windows, most
/// recent first. Bounded, so a long session does not grow it without end:
/// the oldest finished entries go first.
@MainActor
@Observable
final class ActivityLog {
    static let shared = ActivityLog()

    let capacity: Int
    private(set) var entries: [ActivityEntry] = []

    init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    /// Records an operation as started, returning its entry's id to finish it with.
    @discardableResult
    func begin(_ title: String, repository: String?, isBackground: Bool = false, at date: Date = .now) -> UUID {
        let entry = ActivityEntry(
            id: UUID(), title: title, repository: repository, started: date, finished: nil,
            outcome: .running, transfer: nil, isBackground: isBackground
        )
        entries.insert(entry, at: 0)
        trim()
        return entry.id
    }

    /// Names an operation better once it is known, such as the remote a
    /// fetch chose.
    func retitle(_ id: UUID, _ title: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].title = title
    }

    /// Records how an operation ended.
    func finish(_ id: UUID, _ outcome: ActivityEntry.Outcome, transfer: TransferProgress? = nil, at date: Date = .now) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].finished = date
        entries[index].outcome = outcome
        if let transfer {
            entries[index].transfer = transfer
        }
    }

    /// Records how an operation ended from the error it threw, if any.
    func finish(_ id: UUID, error: (any Error)?, transfer: TransferProgress? = nil) {
        let outcome: ActivityEntry.Outcome = switch error {
        case nil: .succeeded
        case is CancellationError: .cancelled
        case let error?: .failed(error.localizedDescription)
        }
        finish(id, outcome, transfer: transfer)
    }

    func clear() {
        // Operations still under way stay, so they can finish.
        entries.removeAll { $0.outcome != .running }
    }

    private func trim() {
        while entries.count > capacity {
            if let index = entries.lastIndex(where: { $0.outcome != .running }) {
                entries.remove(at: index)
            } else {
                entries.removeLast()
            }
        }
    }

    /// "Fetch “origin”" for "Fetching “origin”": the progress titles the
    /// remote operations show, named as things done.
    static func title(forProgress title: String) -> String {
        let words: [(String, String)] = [
            ("Force Pushing", "Force Push"), ("Fetching", "Fetch"), ("Pulling", "Pull"), ("Pushing", "Push"),
            ("Syncing", "Sync"), ("Cloning", "Clone"), ("Deleting", "Delete"), ("Renaming", "Rename"),
            ("Pruning", "Prune"), ("Updating", "Update")
        ]
        for (progressive, done) in words where title.hasPrefix(progressive) {
            return done + title.dropFirst(progressive.count)
        }
        return title
    }
}
