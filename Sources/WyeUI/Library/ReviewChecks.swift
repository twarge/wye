import Foundation
import GitKit

/// The newest commit a hosting service has of an active branch: where a
/// push starts checks, and so where a failure says the branch is broken
/// now, not that it once was.
struct BranchTip: Hashable, Sendable {
    /// The branch as people write it: `main`.
    var branch: String
    /// Its upstream's name: `origin/main`.
    var upstream: String
    /// The upstream's commit, as of the last fetch or push: checks run for
    /// what was pushed, which a branch with unpushed commits is ahead of.
    var commit: OID
    /// When that commit was made; `nil` when it could not be read.
    var committed: Date?

    /// How many of a repository's branches are asked about: a request's
    /// worth on any service, the checked-out one and the newest first.
    static let limit = 25

    /// The upstream tips of a repository's active local branches: those the
    /// sidebar lists as neither archived, by hand or for their age, nor
    /// stale. The checked-out branch always counts. A branch never
    /// published has no tip a service knows of.
    ///
    /// - Parameters:
    ///   - layout: Which branches were archived by hand, as the sidebar keeps it.
    ///   - dates: When the commits that branches point at were made.
    static func active(
        in snapshot: RepositorySnapshot, layout: RepositoryInterfaceState.Stored, dates: [OID: Date],
        now: Date = .now, staleMonths: Int = BranchPreferences.staleMonths,
        autoArchiveMonths: Int = BranchPreferences.autoArchiveMonths, calendar: Calendar = .current
    ) -> [BranchTip] {
        let local = snapshot.branches.filter { !$0.isRemote }
        let pushed = pushedCommits(in: snapshot)
        var review = BranchReview(base: nil)
        for branch in local { review.tipDates[branch.id] = dates[branch.target] }
        let listing = BranchListing(
            branches: local, state: layout, review: review, now: now,
            staleMonths: staleMonths, autoArchiveMonths: autoArchiveMonths, calendar: calendar
        )
        let tips = (listing.pinned + listing.listed).compactMap { branch -> (tip: BranchTip, isHead: Bool)? in
            guard listing.marks[branch.id]?.isStale != true, let upstream = branch.upstream,
                  let commit = pushed[upstream.name] else { return nil }
            let tip = BranchTip(branch: branch.name, upstream: upstream.name, commit: commit, committed: dates[commit])
            return (tip, branch.isHead)
        }
        return tips.sorted { first, second in
            if first.isHead != second.isHead { return first.isHead }
            let (left, right) = (first.tip.committed ?? .distantPast, second.tip.committed ?? .distantPast)
            if left != right { return left > right }
            return first.tip.branch.localizedStandardCompare(second.tip.branch) == .orderedAscending
        }
        .prefix(limit).map(\.tip)
    }

    /// The commits whose dates `active` wants: the local branches' own, to
    /// tell the stale ones, and their upstreams', to tell how long an
    /// answer about them stands. Not every remote branch's: a remote can
    /// have thousands.
    static func commitsToDate(in snapshot: RepositorySnapshot) -> Set<OID> {
        let pushed = pushedCommits(in: snapshot)
        var commits: Set<OID> = []
        for branch in snapshot.branches where !branch.isRemote {
            commits.insert(branch.target)
            if let commit = branch.upstream.flatMap({ pushed[$0.name] }) { commits.insert(commit) }
        }
        return commits
    }

    /// Each remote branch's commit, by the branch's name: `origin/main`. A
    /// snapshot lists remote branches under their remotes.
    private static func pushedCommits(in snapshot: RepositorySnapshot) -> [String: OID] {
        var pushed: [String: OID] = [:]
        for branch in snapshot.remotes.flatMap(\.branches) { pushed[branch.name] = branch.target }
        return pushed
    }
}

/// An active branch whose newest pushed commit failed its checks.
struct FailedCheck: Identifiable, Hashable, Sendable {
    /// The branch as people write it: `main`.
    var branch: String
    /// Its upstream's name: `origin/main`.
    var upstream: String
    /// The commit the checks ran for.
    var commit: OID
    /// The commit's checks on the service's website, where it has such a page.
    var webURL: URL?

    var id: String { branch }

    /// "Checks failed on “main”", and where that was when the upstream is
    /// not simply the branch on a remote: "Checks failed on “main”, at
    /// origin/trunk".
    var sentence: String {
        let isSameName = upstream.split(separator: "/", maxSplits: 1).last.map(String.init) == branch
        return "Checks failed on “\(branch)”" + (isSameName ? "" : ", at \(upstream)")
    }
}

/// Whether the checks of active branches' tips failed, for the repository
/// list: asked of each repository's hosting services, every tip of a
/// repository in one request, and kept for as long as an answer of its kind
/// stands, so that reading the repositories again does not ask again.
/// Several listed folders of one repository share its answers.
///
/// Only failures are shown, but every answer is kept: a tip whose checks
/// passed, or that has none, is not asked about again until that ages.
@MainActor
final class ReviewChecks {
    static var shared: ReviewChecks { ReviewRequests.shared.checks }

    private struct Kept {
        /// `nil`: nothing ran for the commit there, or it is not there.
        var status: CheckStatus?
        var heardAt: Date
    }

    /// By the source's repository, then commit.
    private var kept: [String: [OID: Kept]] = [:]
    /// The requests under way, by source: the next asker waits its turn.
    private var asking: [String: Task<Void, Never>] = [:]

    private let accounts: AccountStore
    private let transport: any HTTPTransport
    private let gate: ReviewServiceGate
    private let now: @Sendable () -> Date

    /// The longest an answer stands when the user asks for the list to be
    /// read again, in seconds.
    nonisolated static let lifetimeWhenAskedAgain: TimeInterval = 15

    /// - Parameter gate: What lets requests through: the one the pull
    ///   requests to review are asked through. See `ReviewRequests.checks`.
    init(
        accounts: AccountStore, transport: any HTTPTransport, gate: ReviewServiceGate,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.accounts = accounts
        self.transport = transport
        self.gate = gate
        self.now = now
    }

    // MARK: Asking

    /// The tips whose checks failed on any service a repository's remotes
    /// are on: the answers kept, or the services' where those are missing
    /// or have aged. None where no account is signed in for them, and where
    /// they could not be asked and never answered before.
    ///
    /// - Parameter asksAgain: Whether to ask whatever was heard lately.
    func failedChecks(for remotes: [Remote], tips: [BranchTip], asksAgain: Bool = false) async -> [FailedCheck] {
        guard !tips.isEmpty else { return [] }
        let sources = await sources(for: remotes)
        for source in sources {
            await refresh(source, tips: tips, asksAgain: asksAgain)
        }
        return tips.compactMap { tip in
            // Failed on any of them: a commit can be on a fork and on the repository it came from.
            guard let source = sources.first(where: { kept[$0.key]?[tip.commit]?.status == .failure }) else { return nil }
            return FailedCheck(
                branch: tip.branch, upstream: tip.upstream, commit: tip.commit,
                webURL: source.hosted.url(forChecksOf: tip.commit)
            )
        }
    }

    /// The repositories to ask for a folder's remotes: each one on a
    /// service whose checks Wye reads, with an account that can read them,
    /// once however many remotes name it.
    func sources(for remotes: [Remote]) async -> [CheckSource] {
        let (accounts, transport) = (accounts, transport)
        // Off the main thread: the first reading of the accounts opens the Keychain.
        return await Task.detached(priority: .utility) {
            Self.sources(for: remotes, accounts: accounts, transport: transport)
        }.value
    }

    nonisolated static func sources(
        for remotes: [Remote], accounts: AccountStore, transport: any HTTPTransport
    ) -> [CheckSource] {
        // Reading the accounts tells which service each self-hosted account's host runs.
        _ = try? accounts.accounts()
        var seen: Set<String> = []
        return HostingTarget.targets(for: remotes).compactMap { target in
            let key = target.hosted.key
            guard !seen.contains(key), let account = target.account(in: accounts),
                  let service = try? account.service(store: accounts, transport: transport),
                  service.capabilities.checkBatchSize > 0 else { return nil }
            seen.insert(key)
            return CheckSource(
                key: key, remote: target.remote, kind: target.kind, path: target.path, hosted: target.hosted,
                accountID: account.id, service: service
            )
        }
    }

    /// Asks a source about the tips whose answers are missing or have aged,
    /// unless it is being left alone, and returns once it has answered or
    /// failed.
    private func refresh(_ source: CheckSource, tips: [BranchTip], asksAgain: Bool) async {
        // Another folder of the same repository may be asking about the same commits.
        while let task = asking[source.signature] { await task.value }
        let due = dueCommits(of: tips, for: source, asksAgain: asksAgain)
        let question = Self.question(source)
        guard !due.isEmpty, !gate.isHeldOff(question, account: source.accountID) else { return }
        let size = source.service.capabilities.checkBatchSize
        let task = Task {
            await gate.enter()
            // An earlier request may have found the account refused while this one waited.
            if !gate.isHeldOff(question, account: source.accountID) {
                do {
                    for start in stride(from: 0, to: due.count, by: size) {
                        let batch = Array(due[start..<min(start + size, due.count)])
                        let answer = try await source.service.checkStatuses(in: source.path, commits: batch.map(\.hex))
                        let date = now()
                        for commit in batch {
                            kept[source.key, default: [:]][commit] = Kept(status: answer[commit.hex], heardAt: date)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    gate.holdOff(question, account: source.accountID, after: error)
                }
            }
            asking[source.signature] = nil
            gate.leave()
        }
        asking[source.signature] = task
        await task.value
    }

    /// What the gate knows this source's checks by: apart from its pull
    /// requests, which a token may be allowed where it is not allowed these.
    private static func question(_ source: CheckSource) -> String {
        source.signature + "|checks"
    }

    /// The tips' commits a source has no answer for, or one that has aged
    /// as the history's marks do: checks that run are asked after often,
    /// what an old commit's checks came to rarely.
    private func dueCommits(of tips: [BranchTip], for source: CheckSource, asksAgain: Bool) -> [OID] {
        let date = now()
        let known = kept[source.key] ?? [:]
        var seen: Set<OID> = []
        return tips.compactMap { tip in
            guard seen.insert(tip.commit).inserted else { return nil }
            guard let answer = known[tip.commit] else { return tip.commit }
            // A commit whose date could not be read is treated as just made.
            let age = tip.committed.map { date.timeIntervalSince($0) } ?? 0
            var lifetime = CommitCheckStore.lifetime(of: answer.status, commitAge: age, isWatched: false)
            if asksAgain { lifetime = min(lifetime, Self.lifetimeWhenAskedAgain) }
            return date.timeIntervalSince(answer.heardAt) >= lifetime ? tip.commit : nil
        }
    }
}
