import Foundation
import GitKit
import Network
import Observation
import TwigShared

/// How one repository has fared with background fetches, for deciding when
/// to try it next.
struct BackgroundFetchRecord: Hashable, Sendable {
    var lastAttempt: Date?
    /// Failures since the last success; each doubles the wait, up to a limit.
    var consecutiveFailures = 0
    /// The last failure was the remote wanting credentials Twig doesn't have.
    var needsCredentials = false
}

/// The network as background fetching sees it.
enum NetworkCondition: Hashable, Sendable {
    case unavailable
    /// Cellular, a personal hotspot, or Low Data Mode.
    case expensive
    case unmetered
}

/// When a repository should be fetched in the background: pure logic, so it
/// can be tested without a network or a clock.
enum BackgroundFetchPolicy {
    enum Decision: Hashable, Sendable {
        case fetch
        /// Not yet: the next attempt is due then.
        case wait(until: Date)
        case skip(SkipReason)
    }

    enum SkipReason: Hashable, Sendable {
        case disabled
        case offline
        case expensiveNetwork
        /// An operation is under way in a window showing it.
        case busy
        case noRemote
    }

    /// The longest wait between attempts, whatever the failures.
    static let maximumBackoff: TimeInterval = 6 * 60 * 60
    /// How long a repository whose remote wants credentials is left alone.
    static let credentialsBackoff: TimeInterval = 24 * 60 * 60

    /// When the next attempt is due after `record`.
    static func nextAttempt(after record: BackgroundFetchRecord, interval: TimeInterval) -> Date? {
        guard let last = record.lastAttempt else { return nil }
        if record.needsCredentials {
            return last.addingTimeInterval(max(interval, credentialsBackoff))
        }
        let factor = pow(2, Double(min(record.consecutiveFailures, 16)))
        return last.addingTimeInterval(min(interval * factor, max(interval, maximumBackoff)))
    }

    static func decide(
        record: BackgroundFetchRecord,
        interval: TimeInterval?,
        now: Date,
        isBusy: Bool,
        hasRemote: Bool,
        network: NetworkCondition,
        allowsExpensiveNetworks: Bool
    ) -> Decision {
        guard let interval else { return .skip(.disabled) }
        guard hasRemote else { return .skip(.noRemote) }
        switch network {
        case .unavailable: return .skip(.offline)
        case .expensive where !allowsExpensiveNetworks: return .skip(.expensiveNetwork)
        case .expensive, .unmetered: break
        }
        if let due = nextAttempt(after: record, interval: interval), due > now {
            return .wait(until: due)
        }
        return isBusy ? .skip(.busy) : .fetch
    }

    /// The record after an attempt that ended with `error`, or succeeded.
    static func record(after error: (any Error)?, at date: Date, previous: BackgroundFetchRecord) -> BackgroundFetchRecord {
        guard let error else { return BackgroundFetchRecord(lastAttempt: date) }
        var record = previous
        record.lastAttempt = date
        record.consecutiveFailures += 1
        record.needsCredentials = Self.wantsCredentials(error)
        return record
    }

    /// Whether a failure is the remote asking for a token or key Twig
    /// doesn't have, or a host key nobody has looked at: things only the
    /// user can fix, which a quiet fetch must not ask about.
    static func wantsCredentials(_ error: any Error) -> Bool {
        guard let error = error as? RemoteError else { return false }
        switch error {
        case .credentialsRequired, .credentialsRejected, .sshKeyRequired, .sshKeysRejected,
             .sshKeysNotAccepted, .unknownHostKey, .hostKeyChanged:
            return true
        default:
            return false
        }
    }

    /// How many commits a fetch brought to the checked-out branch's
    /// upstream: none when the upstream did not move.
    static func newCommits(upstreamBefore: OID?, upstreamAfter: OID?, behindBefore: Int, behindAfter: Int) -> Int {
        guard let upstreamAfter, upstreamAfter != upstreamBefore, behindAfter > 0 else { return 0 }
        return behindAfter > behindBefore ? behindAfter - behindBefore : behindAfter
    }
}

/// Fetches the listed repositories by themselves while the app runs, as the
/// Fetch setting says, and tells the user when new commits arrive for the
/// checked-out branch.
@MainActor
@Observable
final class BackgroundFetcher {
    static let shared = BackgroundFetcher()

    private var records: [UUID: BackgroundFetchRecord] = [:]
    private var loop: Task<Void, Never>?
    private var isRunning = false
    private let monitor = NWPathMonitor()
    private var network = NetworkCondition.unmetered

    private init() {
        monitor.pathUpdateHandler = { path in
            let condition: NetworkCondition = path.status != .satisfied ? .unavailable
                : path.isExpensive || path.isConstrained ? .expensive : .unmetered
            Task { @MainActor in BackgroundFetcher.shared.network = condition }
        }
        monitor.start(queue: DispatchQueue(label: "Twig.BackgroundFetcher.network"))
    }

    /// Starts checking once a minute. Every window asks; the first starts it.
    func start(library: RepositoryLibrary) {
        guard loop == nil else { return }
        loop = Task { [weak self, weak library] in
            while !Task.isCancelled {
                guard let self, let library else { return }
                await self.runDue(in: library)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Fetches every repository whose turn has come, one at a time.
    func runDue(in library: RepositoryLibrary, deadline: Date = .distantFuture) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let interval = FetchPreferences.backgroundInterval.seconds
        guard interval != nil else { return }
        for bookmark in library.listedBookmarks {
            guard !Task.isCancelled, Date.now < deadline else { return }
            let open = OpenRepositories.models(for: bookmark.id)
            let decision = BackgroundFetchPolicy.decide(
                record: records[bookmark.id] ?? BackgroundFetchRecord(),
                interval: interval, now: .now,
                isBusy: open.contains { $0.isBusyForBackgroundWork },
                // Not known until the repository is read; one without
                // fails its fetch and waits longer each time.
                hasRemote: true,
                network: network,
                allowsExpensiveNetworks: FetchPreferences.fetchesOnExpensiveNetworks
            )
            guard decision == .fetch else { continue }
            await fetch(bookmark, in: library, openModels: open)
        }
    }

    private func fetch(_ bookmark: RepositoryBookmark, in library: RepositoryLibrary, openModels: [RepositoryModel]) async {
        let access: RepositoryAccess
        do {
            access = try library.access(to: bookmark)
        } catch {
            records[bookmark.id] = BackgroundFetchPolicy.record(after: error, at: .now, previous: records[bookmark.id] ?? .init())
            return
        }
        let chosen = RepositoryPreferences.defaultRemote(for: bookmark.id)
        let prune = FetchPreferences.prune
        let (id, name, url) = (bookmark.id, bookmark.name, access.url)
        let entry = ActivityLog.shared.begin("Fetch", repository: name, isBackground: true)
        let result = await Task.detached(priority: .utility) { () -> Result<QuietFetchResult, any Error> in
            do {
                return .success(try await Self.quietFetch(at: url, id: id, name: name, chosenRemote: chosen, prune: prune))
            } catch {
                return .failure(error)
            }
        }.value
        withExtendedLifetime(access) {}

        let error: (any Error)? = if case .failure(let error) = result { error } else { nil }
        if case .success(let fetched) = result {
            ActivityLog.shared.retitle(entry, "Fetch “\(fetched.remote)”")
        }
        ActivityLog.shared.finish(entry, error: error)
        records[bookmark.id] = BackgroundFetchPolicy.record(after: error, at: .now, previous: records[bookmark.id] ?? .init())
        guard case .success(let fetched) = result else { return }
        if let summary = fetched.summary {
            RepositoryStatusBoard.shared.record(summary)
        }
        for model in openModels {
            await model.refresh()
        }
        if fetched.newCommits > 0, let upstream = fetched.upstream {
            await FetchNotifications.post(
                repository: id, name: name, branch: fetched.summary?.branch, upstream: upstream, count: fetched.newCommits
            )
        }
    }

    private struct QuietFetchResult: Sendable {
        var remote: String
        var summary: RepositoryStatusSummary?
        var upstream: String?
        var newCommits: Int
    }

    /// Fetches one remote with only the credentials already saved: GitKit
    /// never prompts, so a remote that wants more simply fails.
    private nonisolated static func quietFetch(
        at url: URL, id: UUID, name: String, chosenRemote: String?, prune: Bool
    ) async throws -> QuietFetchResult {
        let repository = try Repository(at: url)
        let before = try await repository.snapshot()
        let head = before.branches.first { $0.isHead }
        let remotes = before.remotes.map(\.name)
        let remote: String?
        if let chosenRemote, remotes.contains(chosenRemote) {
            remote = chosenRemote
        } else if let upstream = head?.upstream?.name,
                  let match = remotes.filter({ upstream.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            remote = match
        } else {
            remote = remotes.contains("origin") ? "origin" : remotes.count == 1 ? remotes.first : nil
        }
        guard let remote else { throw RemoteError.noRemotes }
        let upstreamBefore = Self.upstreamTarget(in: before)
        try await repository.fetch(remote: remote, prune: prune, tags: .automatic, credentials: CredentialStore.shared)
        let after = try await repository.snapshot()
        let hasChanges = try await !repository.status().isEmpty
        let headAfter = after.branches.first { $0.isHead }
        return QuietFetchResult(
            remote: remote,
            summary: RepositoryStatusSummary(snapshot: after, hasUncommittedChanges: hasChanges, id: id, name: name),
            upstream: headAfter?.upstream?.name,
            newCommits: BackgroundFetchPolicy.newCommits(
                upstreamBefore: upstreamBefore, upstreamAfter: Self.upstreamTarget(in: after),
                behindBefore: head?.upstream?.behind ?? 0, behindAfter: headAfter?.upstream?.behind ?? 0
            )
        )
    }

    /// Where the checked-out branch's upstream points.
    private nonisolated static func upstreamTarget(in snapshot: RepositorySnapshot) -> OID? {
        guard let upstream = snapshot.branches.first(where: { $0.isHead })?.upstream?.name else { return nil }
        return snapshot.remotes.flatMap(\.branches).first { $0.name == upstream }?.target
    }
}

extension RepositoryModel {
    /// Whether anything is under way that a background fetch should not
    /// run alongside: a transfer, an operation, a refresh, or a merge,
    /// rebase or other operation waiting to be finished.
    var isBusyForBackgroundWork: Bool {
        isTransferring || isBusy || diskChanges.isOperating || undoStack.isApplying
    }
}
