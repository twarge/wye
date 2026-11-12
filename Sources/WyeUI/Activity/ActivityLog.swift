import Foundation
import GitKit
import Observation
import os

/// One operation Wye ran, for the activity log.
struct ActivityEntry: Identifiable, Hashable, Sendable {
    enum Outcome: Hashable, Sendable {
        case running
        case succeeded
        case cancelled
        /// What went wrong, as the notice said it.
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
    /// Run by Wye itself, such as a scheduled fetch, rather than asked for.
    var isBackground: Bool
    /// What the server said during a network operation, a line each.
    var said: [String] = []

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
    /// Counts of operations the user asked for that are worth feeling end:
    /// a commit or a transfer done, and anything that failed. Views give
    /// haptic feedback as they change.
    private(set) var completions = 0
    private(set) var failures = 0
    /// Failures since the log was last looked at, the automatic ones too:
    /// those are said nowhere else, so the button for the log counts them.
    private(set) var unseenFailures = 0

    /// The same operations in the system's log, for Console and a sysdiagnose:
    /// what ran, how long it took and how it ended. Repository names and
    /// error text are private there, so they show only on the user's own device.
    @ObservationIgnored private let logger = Logger(subsystem: ActivityLog.subsystem, category: "operations")
    @ObservationIgnored private let signposter = OSSignposter(subsystem: ActivityLog.subsystem, category: "operations")
    @ObservationIgnored private var intervals: [UUID: OSSignpostIntervalState] = [:]

    static let subsystem = Bundle.main.bundleIdentifier ?? "com.twarge.app.wye"

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
        logger.info("Began \(title, privacy: .public) in \(repository ?? "-", privacy: .private)")
        intervals[entry.id] = signposter.beginInterval("Operation", id: signposter.makeSignpostID(), "\(title, privacy: .public)")
        return entry.id
    }

    /// Names an operation better once it is known, such as the remote a
    /// fetch chose.
    func retitle(_ id: UUID, _ title: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].title = title
    }

    /// Records how an operation ended.
    func finish(
        _ id: UUID, _ outcome: ActivityEntry.Outcome, transfer: TransferProgress? = nil, said: [String] = [],
        at date: Date = .now
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].finished = date
        entries[index].outcome = outcome
        entries[index].said = said
        if case .failed = outcome { unseenFailures += 1 }
        if let transfer {
            entries[index].transfer = transfer
        }
        record(entries[index])
    }

    /// Whether an operation's success is worth a tap of the Taptic Engine:
    /// the ones that take a while or matter, not each file staged.
    static func isNotable(_ entry: ActivityEntry) -> Bool {
        guard !entry.isBackground else { return false }
        return entry.transfer != nil
            || ["Commit", "Clone", "Pull", "Push", "Fetch", "Sync", "Merge", "Rebase"].contains { entry.title.hasPrefix($0) }
    }

    private func record(_ entry: ActivityEntry) {
        if let interval = intervals.removeValue(forKey: entry.id) {
            signposter.endInterval("Operation", interval)
        }
        let seconds = entry.duration ?? 0
        switch entry.outcome {
        case .running:
            break
        case .succeeded:
            logger.info("Finished \(entry.title, privacy: .public) in \(seconds, format: .fixed(precision: 2))s")
            if Self.isNotable(entry) { completions += 1 }
        case .cancelled:
            logger.info("Cancelled \(entry.title, privacy: .public) after \(seconds, format: .fixed(precision: 2))s")
        case .failed(let message):
            logger.error("Failed \(entry.title, privacy: .public) after \(seconds, format: .fixed(precision: 2))s: \(message, privacy: .private)")
            if !entry.isBackground { failures += 1 }
        }
    }

    /// Records how an operation ended from the error it threw, if any.
    func finish(_ id: UUID, error: (any Error)?, transfer: TransferProgress? = nil, said: [String] = []) {
        let outcome: ActivityEntry.Outcome = switch error {
        case nil: .succeeded
        case is CancellationError: .cancelled
        case let error?: .failed(error.localizedDescription)
        }
        finish(id, outcome, transfer: transfer, said: said)
    }

    /// The log is on screen: its failures have been seen.
    func markSeen() {
        unseenFailures = 0
    }

    func clear() {
        // Operations still under way stay, so they can finish.
        entries.removeAll { $0.outcome != .running }
        unseenFailures = 0
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
