import Foundation
import GitKit
import Observation

/// A local branch, other than the checked-out one, whose upstream has
/// commits it lacks: something to pull that the checked-out branch's own
/// count does not show.
struct BranchToPull: Identifiable, Hashable, Sendable {
    /// The branch as people write it: `release`.
    var name: String
    /// Its upstream's name: `origin/release`.
    var upstream: String
    /// How many commits the upstream has that the branch lacks.
    var behind: Int

    var id: String { name }

    /// What it has to pull, said in full: "“release” has 3 commits to pull
    /// from origin/release".
    var pullSentence: String {
        "“\(name)” has \(RepositoryReview.count(behind, "commit")) to pull from \(upstream)"
    }

    /// The local branches of a repository that are behind their upstreams,
    /// as of the last fetch, leaving out the checked-out one: the Review
    /// says that one's commits itself. A branch that is only ahead of its
    /// upstream is not among them.
    static func others(in snapshot: RepositorySnapshot) -> [BranchToPull] {
        snapshot.branches.compactMap { branch in
            guard !branch.isHead, !branch.isRemote, let upstream = branch.upstream, upstream.behind > 0 else {
                return nil
            }
            return BranchToPull(name: branch.name, upstream: upstream.name, behind: upstream.behind)
        }
    }
}

/// One repository as the list of repositories shows it: where its `HEAD`
/// is, and its reasons to be looked at. Those are work that exists only on
/// this device (what is not committed, and the commits its upstream lacks),
/// the commits there are to pull, on its branch or another, the active
/// branches whose checks failed, and the pull requests that wait for the
/// account's review.
struct RepositoryReview: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// The checked-out branch; `nil` when `HEAD` is detached.
    var branch: String?
    /// The upstream's name, `origin/main`; `nil` when the branch has none.
    var upstream: String?
    var hasRemote: Bool
    var entries: [StatusEntry]
    /// The newest unpushed commits, at most `ReviewModel.commitLimit`.
    var commits: [Commit]
    /// How many commits are unpushed, shown or not.
    var ahead: Int
    /// How many commits the upstream has that the branch lacks, as of the
    /// last fetch.
    var behind: Int
    /// When the newest of the changed files was last written: an edit to a
    /// file already listed as changed shows here, where `entries` stays the same.
    var lastModified: Date? = nil
    /// The other local branches whose upstreams have commits they lack.
    var otherBranches: [BranchToPull] = []
    /// The open pull requests that ask the signed-in account for review, as
    /// the repository's hosting service last said. Empty until it answers,
    /// and where no account is signed in.
    var reviewRequests: [ReviewRequest] = []
    /// Whether the service has more of them than were read.
    var hasMoreReviewRequests = false
    /// The active branches whose newest pushed commits failed their checks,
    /// as the repository's hosting services last said. Empty until they
    /// answer, and where no account is signed in.
    var failedChecks: [FailedCheck] = []
    /// The commit `HEAD` is detached at, abbreviated; `nil` on a branch.
    var detachedAt: String? = nil

    /// A branch with commits and a remote to publish to, but no upstream.
    var isUnpublished: Bool {
        branch != nil && upstream == nil && hasRemote
    }

    /// Whether the checked-out branch has work that exists only on this
    /// device.
    var hasWork: Bool {
        !entries.isEmpty || ahead > 0 || isUnpublished
    }

    /// Whether the repository has something to look at, which its row then
    /// says and folds away: its work, commits to pull, another branch with
    /// commits to pull, an active branch whose checks failed, or a pull
    /// request to review. Unpushed commits on a branch that is not checked
    /// out are not among them.
    var needsAttention: Bool {
        hasWork || behind > 0 || !otherBranches.isEmpty || !failedChecks.isEmpty || !reviewRequests.isEmpty
    }

    /// Whether `query` names the repository, a branch, a changed file, a
    /// commit or a pull request. An empty query matches everything.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return name.localizedStandardContains(query)
            || (branch ?? detachedAt)?.localizedStandardContains(query) == true
            || hasFoldedMatch(for: query)
    }

    /// Whether `query` names something the row folds away, so that a search
    /// opens the row on what it found: a changed file, an unpushed commit,
    /// another branch, or a pull request. Not for an empty query.
    func hasFoldedMatch(for query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return false }
        return entries.contains { $0.path.localizedStandardContains(query) }
            || commits.contains { $0.summary.localizedStandardContains(query) }
            || otherBranches.contains { $0.name.localizedStandardContains(query) }
            || failedChecks.contains { $0.branch.localizedStandardContains(query) }
            || reviewRequests.contains { $0.matches(query) }
    }

    /// What its row says of it, folded away: "3 files changed · 2 staged ·
    /// 1 unpushed commit · 4 commits to pull · checks failed on main ·
    /// 1 pull request to review".
    var summary: String {
        var parts: [String] = []
        let files = entries.count
        if files > 0 { parts.append("\(files) \(files == 1 ? "file" : "files") changed") }
        let conflicted = entries.count(where: \.isConflicted)
        if conflicted > 0 { parts.append("\(conflicted) conflicted") }
        let staged = entries.count { $0.staged != nil }
        if staged > 0 { parts.append("\(staged) staged") }
        if ahead > 0 { parts.append(Self.count(ahead, "unpushed commit")) }
        if isUnpublished { parts.append("branch not published") }
        if behind > 0 { parts.append(Self.count(behind, "commit") + " to pull") }
        if let first = otherBranches.first {
            // One branch by its name, several by how many.
            let branches = otherBranches.count == 1 ? first.name : "\(otherBranches.count) other branches"
            parts.append(Self.count(otherBranches.reduce(0) { $0 + $1.behind }, "commit") + " to pull on " + branches)
        }
        if let first = failedChecks.first {
            // One branch by its name, several by how many.
            parts.append("checks failed on " + (failedChecks.count == 1 ? first.branch : "\(failedChecks.count) branches"))
        }
        if let first = reviewRequests.first {
            let term = first.kind.pullRequestTerm.lowercased()
            let more = hasMoreReviewRequests ? "+" : ""
            parts.append("\(reviewRequests.count)\(more) \(reviewRequests.count == 1 && !hasMoreReviewRequests ? term : term + "s") to review")
        }
        return parts.isEmpty ? "Committed and pushed" : parts.joined(separator: " · ")
    }

    /// What the checked-out branch has to pull, said in full: "2 commits to
    /// pull from origin/main". `nil` when it has nothing.
    var pullSentence: String? {
        behind > 0 ? Self.count(behind, "commit") + " to pull from " + (upstream ?? "its remote") : nil
    }

    /// "1 commit", "3 commits".
    static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(count == 1 ? noun : noun + "s")"
    }
}

/// What the list of repositories totals at its top: "12 uncommitted files,
/// 7 unpushed commits and 2 pull requests to review in 4 repositories".
struct ReviewTotals: Hashable, Sendable {
    var repositories = 0
    var files = 0
    /// Unpushed commits on the checked-out branches.
    var commits = 0
    /// Commits to pull, on the checked-out branches and the others.
    var toPull = 0
    /// Active branches whose checks failed.
    var failedChecks = 0
    var reviewRequests = 0
    /// Whether every one of those is a GitLab merge request, to call them that.
    private var saysMergeRequests = false

    init(_ reviews: [RepositoryReview]) {
        var kinds: Set<HostingKind> = []
        for review in reviews where review.needsAttention {
            repositories += 1
            files += review.entries.count
            commits += review.ahead
            toPull += review.behind + review.otherBranches.reduce(0) { $0 + $1.behind }
            failedChecks += review.failedChecks.count
            reviewRequests += review.reviewRequests.count
            kinds.formUnion(review.reviewRequests.map(\.kind))
        }
        saysMergeRequests = kinds == [.gitlab]
    }

    var sentence: String {
        guard repositories > 0 else { return "Everything is committed, pushed and up to date." }
        var parts: [String] = []
        if files > 0 { parts.append(RepositoryReview.count(files, "uncommitted file")) }
        if commits > 0 { parts.append(RepositoryReview.count(commits, "unpushed commit")) }
        if toPull > 0 { parts.append(RepositoryReview.count(toPull, "commit") + " to pull") }
        if failedChecks > 0 {
            parts.append((failedChecks == 1 ? "1 branch" : "\(failedChecks) branches") + " with failed checks")
        }
        if reviewRequests > 0 {
            parts.append(RepositoryReview.count(reviewRequests, saysMergeRequests ? "merge request" : "pull request") + " to review")
        }
        let work = parts.isEmpty ? "Unpublished branches" : Self.list(parts)
        return "\(work) in \(repositories) \(repositories == 1 ? "repository" : "repositories")"
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ parts: [String]) -> String {
        guard let last = parts.last, parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Reads every listed repository for the list of repositories: one at a
/// time, off the main thread, each shown as soon as it is read. Each
/// repository's hosting services are asked, meanwhile and a few at a time,
/// for the pull requests that wait for the account's review and for the
/// checks of its active branches.
@MainActor
@Observable
final class ReviewModel {
    private(set) var reviews: [UUID: RepositoryReview] = [:]
    /// The repositories whose folders are gone, or hold no repository now.
    private(set) var missing: Set<UUID> = []
    /// Whether the repositories are being read. Not set for the services'
    /// answers, which the list does not wait for.
    private(set) var isLoading = false
    /// Whether every listed repository has been read once, so that the
    /// list can say that nothing wants looking at.
    private(set) var hasLoaded = false
    /// Repositories being pushed from the list, and what came of the last push.
    private(set) var pushing: Set<UUID> = []
    var notice: Notice?

    /// Each repository's remotes, as last read: where its pull requests
    /// and its checks are.
    @ObservationIgnored private var remotes: [UUID: [Remote]] = [:]
    /// Each repository's active branches' tips, as last read.
    @ObservationIgnored private var tips: [UUID: [BranchTip]] = [:]
    private let requests: ReviewRequests
    private let checks: ReviewChecks
    private let board: RepositoryStatusBoard?

    static let commitLimit = 30

    /// - Parameters:
    ///   - requests: Who asks the hosting services for pull requests to
    ///     review, and keeps their answers.
    ///   - checks: Who asks them how the checks of branch tips stand;
    ///     `nil` for the one that asks as `requests` does.
    ///   - board: Where each repository's status goes as it is read, for
    ///     the widgets, the menu bar and the Finder; `nil` tells no one.
    init(requests: ReviewRequests = .shared, checks: ReviewChecks? = nil, board: RepositoryStatusBoard? = nil) {
        self.requests = requests
        self.checks = checks ?? requests.checks
        self.board = board
    }

    /// The repositories with something to look at, by name.
    var needingAttention: [RepositoryReview] {
        reviews.values.filter(\.needsAttention)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads every repository, then returns once the services have
    /// answered too.
    ///
    /// - Parameter asksAgain: Whether to ask the services again whatever
    ///   they said lately, as when the user pulls to refresh.
    func load(_ bookmarks: [RepositoryBookmark], from library: RepositoryLibrary, asksAgain: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        let listed = Set(bookmarks.map(\.id))
        for id in reviews.keys where !listed.contains(id) { reviews[id] = nil }
        for id in remotes.keys where !listed.contains(id) { remotes[id] = nil }
        for id in tips.keys where !listed.contains(id) { tips[id] = nil }
        missing.formIntersection(listed)
        board?.retain(listed)
        await withTaskGroup(of: Void.self) { group in
            for bookmark in bookmarks {
                guard !Task.isCancelled else { break }
                await read(bookmark, from: library)
                let id = bookmark.id
                // Asked while the next repository is read.
                group.addTask { await self.lookUpReviewRequests(for: id, asksAgain: asksAgain) }
                group.addTask { await self.lookUpChecks(for: id, asksAgain: asksAgain) }
            }
            if !Task.isCancelled { hasLoaded = true }
            isLoading = false
        }
    }

    func load(_ bookmark: RepositoryBookmark, from library: RepositoryLibrary) async {
        await read(bookmark, from: library)
        await lookUpReviewRequests(for: bookmark.id, asksAgain: false)
        await lookUpChecks(for: bookmark.id, asksAgain: false)
    }

    /// Reads one repository from its folder. Its pull requests and failed
    /// checks are the ones last heard of, until the services are asked.
    private func read(_ bookmark: RepositoryBookmark, from library: RepositoryLibrary) async {
        let id = bookmark.id
        guard let access = try? library.access(to: bookmark) else {
            forget(id, isMissing: true)
            return
        }
        let (name, url) = (bookmark.name, access.url)
        let (reading, isMissing) = await Task.detached(priority: .userInitiated) { () -> (Reading?, Bool) in
            guard Repository.exists(at: url) else { return (nil, true) }
            let layout = RepositoryInterfaceState.storedLayout(of: id)
            return (try? await Self.read(at: url, id: id, name: name, layout: layout), false)
        }.value
        // Held until the read is done: the folder is only open while it is.
        withExtendedLifetime(access) {}
        guard var reading else {
            forget(id, isMissing: isMissing)
            return
        }
        if let heard = reviews[id] {
            reading.review.reviewRequests = heard.reviewRequests
            reading.review.hasMoreReviewRequests = heard.hasMoreReviewRequests
            // Only of commits that are still tips: a push moves a branch on.
            let commits = Set(reading.tips.map(\.commit))
            reading.review.failedChecks = heard.failedChecks.filter { commits.contains($0.commit) }
        }
        reviews[id] = reading.review
        remotes[id] = reading.remotes
        tips[id] = reading.tips
        missing.remove(id)
        if let board {
            board.record(reading.status)
            FinderStatusPublisher.publish(
                id: id, name: name, root: url, branch: reading.status.branch, entries: reading.review.entries
            )
        }
    }

    /// A repository that could not be read: nothing is known of it.
    private func forget(_ id: UUID, isMissing: Bool) {
        reviews[id] = nil
        remotes[id] = nil
        tips[id] = nil
        if isMissing { missing.insert(id) } else { missing.remove(id) }
    }

    /// Takes how many times the accounts have changed, so that a service
    /// which refused one is asked again once another is signed in.
    func accountsChanged(to count: Int) {
        requests.accountsChanged(to: count)
    }

    /// Asks a repository's hosting services for the pull requests that wait
    /// for the account's review, and shows them. A service that cannot be
    /// asked, or fails, leaves what it last said.
    private func lookUpReviewRequests(for id: UUID, asksAgain: Bool) async {
        guard let remotes = remotes[id], !remotes.isEmpty else {
            show(.none, for: id)
            return
        }
        let answer = await requests.reviewRequests(for: remotes, asksAgain: asksAgain)
        // Not shown where the repository's remotes changed while it was asked.
        guard !Task.isCancelled, self.remotes[id] == remotes else { return }
        show(answer, for: id)
    }

    private func show(_ answer: ReviewRequests.Answer, for id: UUID) {
        guard var review = reviews[id],
              review.reviewRequests != answer.requests || review.hasMoreReviewRequests != answer.hasMore else { return }
        review.reviewRequests = answer.requests
        review.hasMoreReviewRequests = answer.hasMore
        reviews[id] = review
    }

    /// Asks a repository's hosting services how the checks of its active
    /// branches' tips stand, and shows the ones that failed.
    private func lookUpChecks(for id: UUID, asksAgain: Bool) async {
        guard let remotes = remotes[id], let tips = tips[id], !remotes.isEmpty, !tips.isEmpty else {
            show([], for: id)
            return
        }
        let failed = await checks.failedChecks(for: remotes, tips: tips, asksAgain: asksAgain)
        // Not shown where the repository's remotes or branches changed while it was asked.
        guard !Task.isCancelled, self.remotes[id] == remotes, self.tips[id] == tips else { return }
        show(failed, for: id)
    }

    private func show(_ failed: [FailedCheck], for id: UUID) {
        guard var review = reviews[id], review.failedChecks != failed else { return }
        review.failedChecks = failed
        reviews[id] = review
    }

    /// Pushes the checked-out branch, as the Push intent does, then reads
    /// the repository again.
    func push(_ bookmark: RepositoryBookmark, in library: RepositoryLibrary) async {
        guard pushing.insert(bookmark.id).inserted else { return }
        defer { pushing.remove(bookmark.id) }
        let entry = ActivityLog.shared.begin("Push", repository: bookmark.name)
        do {
            let said = try await RepositoryIntentRunner.push(bookmark.id)
            ActivityLog.shared.finish(entry, error: nil)
            notice = Notice(.success, title: "Pushed “\(bookmark.name)”", message: said)
        } catch let failure as IntentFailure {
            ActivityLog.shared.finish(entry, error: failure)
            notice = Notice(
                .failure, title: "Couldn’t Push “\(bookmark.name)”",
                message: PullAllModel.detail(failure.message, name: bookmark.name)
            )
        } catch {
            ActivityLog.shared.finish(entry, error: error)
            notice = Notice(error, during: "Push “\(bookmark.name)”")
        }
        await load(bookmark, from: library)
    }

    /// What one read of a repository's folder gives.
    struct Reading: Sendable {
        var review: RepositoryReview
        /// Where each remote is: enough to ask its service.
        var remotes: [Remote]
        /// The active branches' tips, whose checks are asked about.
        var tips: [BranchTip]
        /// The same reading as the widgets and the menu bar show it.
        var status: RepositoryStatusSummary
    }

    /// What is read of a repository in its folder: nothing is asked of a
    /// remote, so what is to pull is as of the last fetch.
    ///
    /// - Parameter layout: Which of its branches the sidebar has archived
    ///   by hand, which are then not among the active ones.
    nonisolated static func read(
        at url: URL, id: UUID, name: String, layout: RepositoryInterfaceState.Stored = .init()
    ) async throws -> Reading {
        let repository = try Repository(at: url)
        let snapshot = try await repository.snapshot()
        let entries = try await repository.status()
        let head = snapshot.branches.first { $0.isHead }
        var commits: [Commit] = []
        if let head, let upstream = head.upstream, upstream.ahead > 0 {
            let options = HistoryOptions(hiddenReferences: ["refs/remotes/" + upstream.name])
            let cursor = try await repository.openHistory(.reference(head.id), options: options)
            commits = (try? await repository.nextCommits(from: cursor, limit: commitLimit)) ?? []
            await repository.closeHistory(cursor)
        }
        var branch: String?
        var detachedAt: String?
        switch snapshot.head {
        case .branch(let name, _), .unborn(let name):
            branch = name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
        case .detached(let commit):
            detachedAt = commit.abbreviated()
        }
        let review = RepositoryReview(
            id: id, name: name, branch: branch, upstream: head?.upstream?.name,
            hasRemote: !snapshot.remotes.isEmpty, entries: entries, commits: commits,
            ahead: head?.upstream?.ahead ?? 0, behind: head?.upstream?.behind ?? 0,
            lastModified: lastModified(of: entries, in: url),
            otherBranches: BranchToPull.others(in: snapshot), detachedAt: detachedAt
        )
        // Only where each remote is: its branches are not needed to ask its service.
        let remotes = snapshot.remotes.map { Remote(name: $0.name, url: $0.url, branches: []) }
        // Tips are only worth working out where there is a service to ask.
        var tips: [BranchTip] = []
        if !HostingTarget.targets(for: remotes).isEmpty {
            let dates = await repository.commitDates(of: BranchTip.commitsToDate(in: snapshot))
            tips = BranchTip.active(in: snapshot, layout: layout, dates: dates)
        }
        let status = RepositoryStatusSummary(snapshot: snapshot, hasUncommittedChanges: !entries.isEmpty, id: id, name: name)
        return Reading(review: review, remotes: remotes, tips: tips, status: status)
    }

    /// The newest of the changed files' modification dates, for the first
    /// few hundred: enough to tell that something was edited.
    private nonisolated static func lastModified(of entries: [StatusEntry], in root: URL) -> Date? {
        entries.prefix(300).compactMap { entry in
            try? root.appending(path: entry.path).resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        }.max()
    }
}
