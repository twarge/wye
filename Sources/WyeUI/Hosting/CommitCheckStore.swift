import Foundation
import GitKit
import Observation

/// A repository on a hosting service whose checks are read for the
/// history's marks: one of the window's remotes, and the account that
/// reads it.
struct CheckSource: Identifiable, Sendable {
    /// `host/owner/project`, the same for every address of the repository:
    /// what its answers are kept by.
    var key: String
    var remote: String
    var kind: HostingKind
    var path: RepositoryPath
    var hosted: HostedRepository
    var accountID: UUID
    var service: any HostingService

    var id: String { key }

    /// The repository and who reads it: another account may see what this
    /// one could not.
    var signature: String { key + "|" + accountID.uuidString }
}

/// How the checks of a repository's commits stand on its hosting services:
/// asked for as the history shows commits, a request for many at a time,
/// kept in memory for the window and in a file between launches, and asked
/// for again as each answer ages.
///
/// A commit can be on several services (a fork and the repository it came
/// from, a mirror), so each service's answer is kept apart and the mark on
/// a commit stands for all of them: failed if any failed.
@MainActor
@Observable
final class CommitCheckStore {
    /// What was last heard about one commit on one repository.
    struct Entry: Codable, Hashable, Sendable {
        /// `nil`: nothing was run for it there, or it is not there.
        var status: CheckStatus?
        var fetchedAt: Date
        /// Each check, once the commit's popover has asked for them.
        var runs: [CheckRun]?
        var runsFetchedAt: Date?

        enum CodingKeys: String, CodingKey {
            case status = "s", fetchedAt = "t", runs = "r", runsFetchedAt = "rt"
        }
    }

    /// One repository's part of a commit's popover.
    struct Section: Identifiable {
        var source: CheckSource
        var entry: Entry

        var id: String { source.key }
    }

    /// How each commit's checks stand over every source: what the
    /// history's rows show. Commits nothing ran for are not in it.
    private(set) var statuses: [OID: CheckStatus] = [:]
    /// The repositories read. None, and nothing is shown.
    private(set) var sources: [CheckSource] = []
    /// Counts the times everything may have changed at once, a push among
    /// them, for whoever is waiting to ask again to start over.
    private(set) var epoch = 0
    /// The commits whose checks are being listed, for their popovers.
    private(set) var loadingRuns: Set<OID> = []
    /// Why a commit's checks could not be listed.
    private(set) var runFailures: [OID: String] = [:]

    /// By source, then commit.
    private var entries: [String: [OID: Entry]] = [:]
    /// The commits the history shows, in its order, and when each was committed.
    @ObservationIgnored private var wanted: [(id: OID, date: Date)] = []
    /// The commits branches and tags point at: where a push starts checks.
    @ObservationIgnored private var tips: Set<OID> = []
    /// Until when the tips are asked about often. See `remotesChanged()`.
    @ObservationIgnored private var watchingTipsUntil: Date?
    /// Answers heard before this are asked for again. See `reload()`.
    @ObservationIgnored private var staleBefore: Date?
    @ObservationIgnored private var cachesRead: Set<String> = []
    /// Sources that failed, by signature, and when to try them again.
    @ObservationIgnored private var heldOff: [String: Date] = [:]
    @ObservationIgnored private var failureCounts: [String: Int] = [:]
    /// The failure last put in the activity log for each source.
    @ObservationIgnored private var reported: [String: String] = [:]
    @ObservationIgnored private var round: Task<Void, Never>?
    @ObservationIgnored private var wantsAnotherRound = false
    @ObservationIgnored private var saves: [String: Task<Void, Never>] = [:]

    private let cache: CheckCache?
    private let repositoryName: String
    private let now: @Sendable () -> Date

    /// How many requests one round makes of a source, before it looks
    /// again at what is wanted: the history may have moved on.
    static let batchesPerRound = 6

    /// - Parameter cache: Where answers are kept between launches; `nil`
    ///   keeps them in memory only.
    init(repositoryName: String, cache: CheckCache? = .standard, now: @escaping @Sendable () -> Date = { .now }) {
        self.repositoryName = repositoryName
        self.cache = cache
        self.now = now
    }

    // MARK: What is shown

    /// Takes the commits the history lists now, the commits its branches
    /// and tags point at, and the repositories to ask. `refresh()` then asks.
    func show(_ commits: some Sequence<Commit>, tips: Set<OID>, sources: [CheckSource]) {
        wanted = commits.map { ($0.id, $0.committer.date) }
        self.tips = tips
        guard sources.map(\.signature) != self.sources.map(\.signature) else { return }
        self.sources = sources
        // Another account, or the same one signed in again, may be let in.
        heldOff = [:]
        failureCounts = [:]
        publishAll()
    }

    /// Each repository's answer for a commit, where it has one.
    func sections(for commit: OID) -> [Section] {
        sources.compactMap { source in
            guard let entry = entries[source.key]?[commit], entry.status != nil || entry.runs?.isEmpty == false else {
                return nil
            }
            return Section(source: source, entry: entry)
        }
    }

    /// How long to wait before `refresh()` is worth calling again: not
    /// long while checks run or a push may be starting some.
    var pollInterval: Duration {
        if let until = watchingTipsUntil, until > now() { return .seconds(10) }
        return wanted.contains { statuses[$0.id] == .pending } ? .seconds(20) : .seconds(60)
    }

    /// A fetch, pull or push just finished: checks may be starting for
    /// what it brought or sent. For a couple of minutes the commits that
    /// branches and tags point at are asked about every few seconds, since
    /// a service takes a moment to start a commit's checks.
    func remotesChanged() {
        watchingTipsUntil = now().addingTimeInterval(120)
        epoch += 1
    }

    /// Asks again about every commit shown, whatever is known: the user
    /// asked for the history to be read again.
    func reload() {
        staleBefore = now()
        heldOff = [:]
        epoch += 1
    }

    // MARK: Asking

    /// Asks the services about the commits shown whose answers are missing
    /// or have aged, and returns once they have answered. Called while one
    /// round is under way, it waits for that one, which then looks again.
    func refresh() async {
        if let round {
            wantsAnotherRound = true
            await round.value
            return
        }
        let task = Task {
            repeat {
                wantsAnotherRound = false
                await runRound()
            } while wantsAnotherRound
            round = nil
        }
        round = task
        await task.value
    }

    private func runRound() async {
        let sources = sources
        guard !sources.isEmpty else { return }
        await readCaches(of: sources)
        guard !wanted.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await self.ask(source) }
            }
        }
    }

    /// One source's round: what is due, a request's worth at a time, top
    /// of the history first, each answer shown as it comes.
    private func ask(_ source: CheckSource) async {
        let size = source.service.capabilities.checkBatchSize
        if let until = heldOff[source.signature], until > now() { return }
        guard size > 0 else { return }
        let limit = size * Self.batchesPerRound
        let due = dueCommits(for: source, limit: limit)
        for start in stride(from: 0, to: due.count, by: size) {
            // Signed out, or the remote removed, while this was asking.
            guard sources.contains(where: { $0.signature == source.signature }) else { return }
            let batch = Array(due[start..<min(start + size, due.count)])
            do {
                let answer = try await source.service.checkStatuses(in: source.path, commits: batch.map(\.hex))
                take(answer, for: batch, from: source)
            } catch is CancellationError {
                return
            } catch {
                holdOff(source, after: error)
                return
            }
        }
        // More than a round's worth: the next takes up where this stopped.
        if due.count == limit { wantsAnotherRound = true }
    }

    private func dueCommits(for source: CheckSource, limit: Int) -> [OID] {
        let date = now()
        let known = entries[source.key] ?? [:]
        let watchesTips = watchingTipsUntil.map { $0 > date } ?? false
        var due: [OID] = []
        for (commit, committed) in wanted {
            if let entry = known[commit], staleBefore.map({ entry.fetchedAt >= $0 }) ?? true {
                let lifetime = Self.lifetime(
                    of: entry.status, commitAge: date.timeIntervalSince(committed),
                    isWatched: watchesTips && tips.contains(commit)
                )
                if date.timeIntervalSince(entry.fetchedAt) < lifetime { continue }
            }
            due.append(commit)
            if due.count == limit { break }
        }
        return due
    }

    /// How long an answer stands before the service is asked again, in
    /// seconds. Checks that run are asked after often, and a commit just
    /// made may get checks any moment; what an old commit's checks came to
    /// rarely changes, though anyone can run them again.
    static func lifetime(of status: CheckStatus?, commitAge: TimeInterval, isWatched: Bool) -> TimeInterval {
        let minute: TimeInterval = 60, hour = 60 * minute, day = 24 * hour
        if status == .pending {
            return commitAge < 30 * minute ? 20 : commitAge < 6 * hour ? minute : 5 * minute
        }
        if status == nil, isWatched { return 10 }
        if commitAge < hour { return status == nil ? 45 : 2 * minute }
        if commitAge < day { return 10 * minute }
        return commitAge < 30 * day ? 12 * hour : 7 * day
    }

    private func take(_ answer: [String: CheckStatus], for batch: [OID], from source: CheckSource) {
        let date = now()
        var known = entries[source.key] ?? [:]
        for commit in batch {
            var entry = known[commit] ?? Entry(status: nil, fetchedAt: date)
            entry.status = answer[commit.hex]
            entry.fetchedAt = date
            known[commit] = entry
        }
        entries[source.key] = known
        heldOff[source.signature] = nil
        failureCounts[source.signature] = nil
        reported[source.signature] = nil
        publish(batch)
        scheduleSave(of: source.key)
    }

    /// Leaves a source alone for a while after it failed: longer each
    /// time, and long at once where asking again cannot help. The history
    /// is whole without its marks, so the failure goes in the activity log
    /// and nowhere else.
    private func holdOff(_ source: CheckSource, after error: any Error) {
        let count = (failureCounts[source.signature] ?? 0) + 1
        failureCounts[source.signature] = count
        let date = now()
        let delay: TimeInterval = switch error as? HostingError {
        case .unauthorized, .forbidden, .notFound, .noAccount, .unsupported: 15 * 60
        case .rateLimited(_, let reset): max(60, reset.map { $0.timeIntervalSince(date) } ?? 5 * 60)
        case .offline: 30
        default: min(15 * 60, 30 * pow(2, Double(min(count, 5))))
        }
        heldOff[source.signature] = date.addingTimeInterval(delay)
        let message = error.localizedDescription
        guard (error as? HostingError) != .offline, reported[source.signature] != message else { return }
        reported[source.signature] = message
        let logged = ActivityLog.shared.begin("Read Checks from \(source.remote)", repository: repositoryName, isBackground: true)
        ActivityLog.shared.finish(logged, error: error)
    }

    // MARK: One commit's checks

    /// Lists every check of a commit, on each repository that has any, for
    /// its popover. What was listed before shows until the answer comes.
    func loadRuns(for commit: OID) async {
        guard !loadingRuns.contains(commit) else { return }
        loadingRuns.insert(commit)
        runFailures[commit] = nil
        defer { loadingRuns.remove(commit) }
        let sources = sources
        await readCaches(of: sources)
        let hex = commit.hex
        await withTaskGroup(of: (CheckSource, Result<CommitChecks, any Error>).self) { group in
            for source in sources where source.service.capabilities.checkBatchSize > 0 {
                group.addTask {
                    do {
                        return (source, .success(try await source.service.checks(in: source.path, commit: hex)))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, result) in group {
                switch result {
                case .success(let checks):
                    let date = now()
                    entries[source.key, default: [:]][commit] = Entry(
                        status: checks.status, fetchedAt: date, runs: checks.runs, runsFetchedAt: date
                    )
                    scheduleSave(of: source.key)
                case .failure(let error):
                    if !(error is CancellationError) { runFailures[commit] = error.localizedDescription }
                }
            }
        }
        publish([commit])
    }

    // MARK: Publishing

    /// Works out the marks of some commits again.
    private func publish(_ commits: some Sequence<OID>) {
        var updated = statuses
        for commit in commits {
            updated[commit] = CheckStatus.merged(sources.compactMap { entries[$0.key]?[commit]?.status })
        }
        // Not set when the same: every row of the history reads them.
        if updated != statuses { statuses = updated }
    }

    /// Works out every mark again, for other sources or a cache just read.
    private func publishAll() {
        var merged: [OID: CheckStatus] = [:]
        for source in sources {
            for (commit, entry) in entries[source.key] ?? [:] {
                guard let status = entry.status else { continue }
                merged[commit] = CheckStatus.merged([merged[commit], status].compactMap { $0 })
            }
        }
        if merged != statuses { statuses = merged }
    }

    // MARK: Between launches

    /// Reads what was kept for the sources, once each. What has been
    /// heard since this launch stands over it.
    private func readCaches(of sources: [CheckSource]) async {
        guard let cache else { return }
        var read = false
        for source in sources where !cachesRead.contains(source.key) {
            cachesRead.insert(source.key)
            let kept = await cache.load(source.key)
            guard !kept.isEmpty else { continue }
            entries[source.key] = kept.merging(entries[source.key] ?? [:]) { _, heard in heard }
            read = true
        }
        if read { publishAll() }
    }

    /// Writes a source's answers soon, once for however many arrive together.
    private func scheduleSave(of key: String) {
        guard cache != nil, saves[key] == nil else { return }
        saves[key] = Task {
            try? await Task.sleep(for: .seconds(2))
            saves[key] = nil
            await save(key)
        }
    }

    private func save(_ key: String) async {
        guard let cache, let kept = entries[key] else { return }
        await cache.save(kept, for: key)
    }

    /// Writes everything now, without waiting to see what else arrives.
    func saveNow() async {
        for task in saves.values { task.cancel() }
        saves = [:]
        for key in entries.keys { await save(key) }
    }
}

/// Where commits' checks are kept between launches: a file for each
/// repository on a service, in the app's caches, which the system may
/// clear. Nothing in it cannot be asked for again.
struct CheckCache: Sendable {
    var directory: URL

    static let standard = CheckCache(directory: .cachesDirectory.appending(path: "Wye/Checks", directoryHint: .isDirectory))

    /// How many commits' answers a file keeps: the most recently heard.
    static let limit = 10_000
    /// How many of those keep each of their checks, which take more room.
    static let runsLimit = 200

    private struct File: Codable {
        var version = 1
        /// By the commit's full hash.
        var entries: [String: CommitCheckStore.Entry]
    }

    /// A file named for the repository, with nothing a file name cannot hold.
    func file(for key: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return directory.appending(path: name + ".json", directoryHint: .notDirectory)
    }

    func load(_ key: String) async -> [OID: CommitCheckStore.Entry] {
        let url = file(for: key)
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return [:] }
            var entries: [OID: CommitCheckStore.Entry] = [:]
            entries.reserveCapacity(file.entries.count)
            for (hash, entry) in file.entries {
                if let commit = OID(hex: hash) { entries[commit] = entry }
            }
            return entries
        }.value
    }

    func save(_ entries: [OID: CommitCheckStore.Entry], for key: String) async {
        let url = file(for: key)
        await Task.detached(priority: .utility) {
            let file = File(entries: Self.trimmed(entries))
            guard let data = try? JSONEncoder().encode(file) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }.value
    }

    /// What a file keeps of a source's answers: the newest, and the lists
    /// of checks of the newest few of those.
    static func trimmed(
        _ entries: [OID: CommitCheckStore.Entry], limit: Int = limit, runsLimit: Int = runsLimit
    ) -> [String: CommitCheckStore.Entry] {
        var kept = Array(entries)
        if kept.count > limit {
            kept.sort { $0.value.fetchedAt > $1.value.fetchedAt }
            kept.removeLast(kept.count - limit)
        }
        let withRuns = kept.compactMap { $0.value.runsFetchedAt }.sorted(by: >)
        let oldestKept = withRuns.count > runsLimit ? withRuns[runsLimit - 1] : nil
        var file: [String: CommitCheckStore.Entry] = [:]
        file.reserveCapacity(kept.count)
        for (commit, entry) in kept {
            var entry = entry
            if let oldestKept, let listed = entry.runsFetchedAt, listed < oldestKept {
                entry.runs = nil
                entry.runsFetchedAt = nil
            }
            file[commit.hex] = entry
        }
        return file
    }
}
