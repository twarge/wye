import Foundation
import GitKit
import Observation

/// How pulling one repository went, as Pull All reports it.
struct PullAllResult: Identifiable, Hashable, Sendable {
    enum Outcome: Hashable, Sendable {
        /// Still waiting its turn.
        case waiting
        case pulling
        case upToDate
        /// New commits arrived; the sentence says how.
        case updated(String)
        /// Nothing to pull from, which is no failure: the sentence says why.
        case skipped(String)
        /// The pull stopped part way and wants the user.
        case needsAttention(String)
        case failed(String)
    }

    var id: UUID
    var name: String
    var outcome: Outcome

    var isFinished: Bool {
        switch outcome {
        case .waiting, .pulling: false
        case .upToDate, .updated, .skipped, .needsAttention, .failed: true
        }
    }

    /// Whether the user has something to do about it.
    var isProblem: Bool {
        switch outcome {
        case .needsAttention, .failed: true
        case .waiting, .pulling, .upToDate, .updated, .skipped: false
        }
    }
}

/// Pure logic of Pull All, so it can be tested without a repository.
enum PullAllReport {
    /// Why a repository has nothing to pull, or `nil` when it can be pulled.
    static func skipReason(for snapshot: RepositorySnapshot) -> String? {
        if snapshot.remotes.isEmpty { return "No remote." }
        switch snapshot.head {
        case .detached: return "No branch is checked out."
        case .unborn: return "The branch has no commits yet."
        case .branch: break
        }
        if snapshot.state != .clean { return "An operation is waiting to be finished." }
        guard snapshot.branches.first(where: \.isHead)?.upstream != nil else {
            return "The branch tracks no remote branch."
        }
        return nil
    }

    /// One line for the whole run: "3 updated, 12 up to date, 1 failed".
    static func summary(of results: [PullAllResult]) -> String {
        var updated = 0, upToDate = 0, skipped = 0, attention = 0, failed = 0
        for result in results {
            switch result.outcome {
            case .updated: updated += 1
            case .upToDate: upToDate += 1
            case .skipped: skipped += 1
            case .needsAttention: attention += 1
            case .failed: failed += 1
            case .waiting, .pulling: break
            }
        }
        var parts: [String] = []
        if updated > 0 { parts.append("\(updated) updated") }
        if upToDate > 0 { parts.append("\(upToDate) up to date") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if attention > 0 { parts.append("\(attention) need attention") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "Nothing to pull." : parts.joined(separator: ", ")
    }

    /// Problems first, then what changed, then the rest; by name within each.
    static func sorted(_ results: [PullAllResult]) -> [PullAllResult] {
        results.sorted { first, second in
            let ranks = (rank(first.outcome), rank(second.outcome))
            if ranks.0 != ranks.1 { return ranks.0 < ranks.1 }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    private static func rank(_ outcome: PullAllResult.Outcome) -> Int {
        switch outcome {
        case .pulling: 0
        case .failed: 1
        case .needsAttention: 2
        case .updated: 3
        case .waiting: 4
        case .skipped: 5
        case .upToDate: 6
        }
    }
}

/// Pulls every listed repository, a few at a time, and keeps what became of
/// each for the report.
@MainActor
@Observable
final class PullAllModel {
    private(set) var results: [PullAllResult] = []
    private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var workers: [Task<Void, Never>] = []
    private var continued: ContinuedWork.Handle?

    /// How many repositories are pulled at once.
    static let width = 4

    var finishedCount: Int { results.count { $0.isFinished } }
    var problems: [PullAllResult] { results.filter(\.isProblem) }

    func start(_ bookmarks: [RepositoryBookmark]) {
        guard !isRunning else { return }
        results = bookmarks.map { PullAllResult(id: $0.id, name: $0.name, outcome: .waiting) }
        isRunning = true
        // A few workers, each taking the next repository as it finishes one.
        // They all run on the main actor, so the queue needs no lock; the
        // pulls themselves happen in each repository's own actor.
        var waiting = bookmarks[...]
        let workers = (0..<min(Self.width, bookmarks.count)).map { _ in
            Task {
                while !Task.isCancelled, let bookmark = waiting.popFirst() {
                    await pull(bookmark)
                }
            }
        }
        self.workers = workers
        let continued = ContinuedWork.begin("Pulling All Repositories", subtitle: "Starting") { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        self.continued = continued
        task = Task {
            for worker in workers { await worker.value }
            continued.finish(success: problems.isEmpty)
            self.continued = nil
            for index in results.indices where !results[index].isFinished {
                results[index].outcome = .skipped("Cancelled.")
            }
            isRunning = false
        }
    }

    func cancel() {
        for worker in workers { worker.cancel() }
    }

    private func set(_ outcome: PullAllResult.Outcome, for id: UUID) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].outcome = outcome
        continued?.report(
            completed: finishedCount, of: results.count,
            subtitle: "\(finishedCount) of \(results.count) repositories"
        )
    }

    /// A failure as its row says it: without the repository's name in
    /// front, which a sentence said on its own needs and a row under that
    /// name does not.
    static func detail(_ message: String, name: String) -> String {
        let prefix = name + ": "
        guard message.hasPrefix(prefix), message.count > prefix.count else { return message }
        let rest = message.dropFirst(prefix.count)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    private func pull(_ bookmark: RepositoryBookmark) async {
        guard !Task.isCancelled else { return }
        set(.pulling, for: bookmark.id)
        let entry = ActivityLog.shared.begin("Pull", repository: bookmark.name)
        do {
            let outcome = try await RepositoryIntentRunner.pullQuietly(bookmark.id)
            ActivityLog.shared.finish(entry, error: nil)
            set(outcome, for: bookmark.id)
        } catch let failure as IntentFailure {
            ActivityLog.shared.finish(entry, error: failure)
            set(.failed(Self.detail(failure.message, name: bookmark.name)), for: bookmark.id)
        } catch {
            ActivityLog.shared.finish(entry, error: error)
            set(.failed(error.localizedDescription), for: bookmark.id)
        }
    }
}

extension RepositoryIntentRunner {
    /// Pulls one repository for Pull All: never asks anything, and tells a
    /// repository with nothing to pull from apart from one that failed.
    static func pullQuietly(_ id: UUID) async throws -> PullAllResult.Outcome {
        try await run("Pulling", on: id) { repository, _ in
            let snapshot = try await repository.snapshot()
            if let reason = PullAllReport.skipReason(for: snapshot) {
                return .skipped(reason)
            }
            let branch = snapshot.branches.first(where: \.isHead)?.name ?? "the branch"
            let before = snapshot.head.target
            let mode = await repository.configuredPullMode() ?? RemotePreferences.pullMode
            let outcome = try await repository.pull(
                options: PullOptions(mode: mode, autostash: RemotePreferences.autostash == .always),
                credentials: CredentialStore.shared
            )
            let count = if let before { try await repository.headCommitCount(notIn: before) } else { 0 }
            let sentence = IntentPhrasing.pulled(outcome, count: count, branch: branch)
            // Local changes that did not go back where they were want the
            // user as much as a conflict in the pull itself does.
            let changesAreBack = switch outcome.autostash {
            case .notNeeded, .restored: true
            default: false
            }
            if outcome.result.stoppedOnConflicts || !changesAreBack { return .needsAttention(sentence) }
            return outcome.result == .upToDate ? .upToDate : .updated(sentence)
        }
    }
}
