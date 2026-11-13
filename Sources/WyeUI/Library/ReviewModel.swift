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

/// One repository's reasons to be looked at: work that exists only on this
/// device (what is not committed, and the commits its upstream lacks), the
/// commits there are to pull, on its branch or another, and the pull
/// requests that wait for the account's review.
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

    /// A branch with commits and a remote to publish to, but no upstream.
    var isUnpublished: Bool {
        branch != nil && upstream == nil && hasRemote
    }

    /// Whether the checked-out branch has work that exists only on this
    /// device.
    var hasWork: Bool {
        !entries.isEmpty || ahead > 0 || isUnpublished
    }

    /// Whether the Review lists the repository: for its work, for commits
    /// to pull, for another branch with commits to pull, or for a pull
    /// request to review. Unpushed commits on a branch that is not checked
    /// out do not list it.
    var needsAttention: Bool {
        hasWork || behind > 0 || !otherBranches.isEmpty || !reviewRequests.isEmpty
    }

    /// Whether `query` names the repository, a branch, a changed file, a
    /// commit or a pull request. An empty query matches everything.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return name.localizedStandardContains(query)
            || branch?.localizedStandardContains(query) == true
            || entries.contains { $0.path.localizedStandardContains(query) }
            || commits.contains { $0.summary.localizedStandardContains(query) }
            || otherBranches.contains { $0.name.localizedStandardContains(query) }
            || reviewRequests.contains { $0.matches(query) }
    }

    /// What its row says of it, folded away: "3 files changed · 2 staged ·
    /// 1 unpushed commit · 4 commits to pull · 1 pull request to review".
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

/// What the Review totals at its top: "12 uncommitted files, 7 unpushed
/// commits and 2 pull requests to review in 4 repositories".
struct ReviewTotals: Hashable, Sendable {
    var repositories = 0
    var files = 0
    /// Unpushed commits on the checked-out branches.
    var commits = 0
    /// Commits to pull, on the checked-out branches and the others.
    var toPull = 0
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

/// Reads every listed repository for the Review: one at a time, off the
/// main thread, each shown as soon as it is read. Each repository's hosting
/// service is asked, meanwhile and a few at a time, for the pull requests
/// that wait for the account's review.
@MainActor
@Observable
final class ReviewModel {
    private(set) var reviews: [UUID: RepositoryReview] = [:]
    /// Whether the repositories are being read. Not set for the services'
    /// answers, which the Review does not wait for.
    private(set) var isLoading = false
    /// Repositories being pushed from the Review, and what came of the last push.
    private(set) var pushing: Set<UUID> = []
    var notice: Notice?

    /// Each repository's remotes, as last read: where its pull requests are.
    @ObservationIgnored private var remotes: [UUID: [Remote]] = [:]
    private let requests: ReviewRequests

    static let commitLimit = 30

    /// - Parameter requests: Who asks the hosting services, and keeps
    ///   their answers.
    init(requests: ReviewRequests = .shared) {
        self.requests = requests
    }

    /// The repositories the Review lists, by name.
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
        await withTaskGroup(of: Void.self) { group in
            for bookmark in bookmarks {
                guard !Task.isCancelled else { break }
                await read(bookmark, from: library)
                let id = bookmark.id
                // Asked while the next repository is read.
                group.addTask { await self.lookUpReviewRequests(for: id, asksAgain: asksAgain) }
            }
            isLoading = false
        }
    }

    func load(_ bookmark: RepositoryBookmark, from library: RepositoryLibrary) async {
        await read(bookmark, from: library)
        await lookUpReviewRequests(for: bookmark.id, asksAgain: false)
    }

    /// Reads one repository from its folder. Its pull requests are the ones
    /// last heard of, until `lookUpReviewRequests` asks.
    private func read(_ bookmark: RepositoryBookmark, from library: RepositoryLibrary) async {
        guard let access = try? library.access(to: bookmark) else {
            reviews[bookmark.id] = nil
            remotes[bookmark.id] = nil
            return
        }
        let (id, name, url) = (bookmark.id, bookmark.name, access.url)
        let read = await Task.detached(priority: .userInitiated) {
            try? await Self.read(at: url, id: id, name: name)
        }.value
        // Held until the read is done: the folder is only open while it is.
        withExtendedLifetime(access) {}
        var review = read?.review
        if let heard = reviews[bookmark.id] {
            review?.reviewRequests = heard.reviewRequests
            review?.hasMoreReviewRequests = heard.hasMoreReviewRequests
        }
        reviews[bookmark.id] = review
        remotes[bookmark.id] = read?.remotes
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

    /// What is read of a repository in its folder: nothing is asked of a
    /// remote, so what is to pull is as of the last fetch.
    nonisolated static func read(
        at url: URL, id: UUID, name: String
    ) async throws -> (review: RepositoryReview, remotes: [Remote]) {
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
        let branch: String? = switch snapshot.head {
        case .branch(let name, _), .unborn(let name):
            name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
        case .detached: nil
        }
        let review = RepositoryReview(
            id: id, name: name, branch: branch, upstream: head?.upstream?.name,
            hasRemote: !snapshot.remotes.isEmpty, entries: entries, commits: commits,
            ahead: head?.upstream?.ahead ?? 0, behind: head?.upstream?.behind ?? 0,
            lastModified: lastModified(of: entries, in: url),
            otherBranches: BranchToPull.others(in: snapshot)
        )
        // Only where each remote is: its branches are not needed to ask its service.
        return (review, snapshot.remotes.map { Remote(name: $0.name, url: $0.url, branches: []) })
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
