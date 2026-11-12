import Foundation
import GitKit
import Observation

/// One repository's work that exists only on this device: what is not
/// committed, and the commits its upstream lacks.
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
    var behind: Int

    /// A branch with commits and a remote to publish to, but no upstream.
    var isUnpublished: Bool {
        branch != nil && upstream == nil && hasRemote
    }

    var hasWork: Bool {
        !entries.isEmpty || ahead > 0 || isUnpublished
    }

    /// Whether `query` names the repository, its branch, a changed file or
    /// a commit. An empty query matches everything.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return name.localizedStandardContains(query)
            || branch?.localizedStandardContains(query) == true
            || entries.contains { $0.path.localizedStandardContains(query) }
            || commits.contains { $0.summary.localizedStandardContains(query) }
    }
}

/// What the Review totals at its top: "12 files in 3 repositories, 7 commits to push".
struct ReviewTotals: Hashable, Sendable {
    var repositories = 0
    var files = 0
    var commits = 0

    init(_ reviews: [RepositoryReview]) {
        for review in reviews where review.hasWork {
            repositories += 1
            files += review.entries.count
            commits += review.ahead
        }
    }

    var sentence: String {
        guard repositories > 0 else { return "Everything is committed and pushed." }
        var parts: [String] = []
        if files > 0 { parts.append("\(files) uncommitted \(files == 1 ? "file" : "files")") }
        if commits > 0 { parts.append("\(commits) unpushed \(commits == 1 ? "commit" : "commits")") }
        let work = parts.isEmpty ? "Unpublished branches" : parts.joined(separator: " and ")
        return "\(work) in \(repositories) \(repositories == 1 ? "repository" : "repositories")"
    }
}

/// Reads every listed repository for the Review: one at a time, off the
/// main thread, each shown as soon as it is read.
@MainActor
@Observable
final class ReviewModel {
    private(set) var reviews: [UUID: RepositoryReview] = [:]
    private(set) var isLoading = false
    /// Repositories being pushed from the Review, and what came of the last push.
    private(set) var pushing: Set<UUID> = []
    var notice: Notice?

    static let commitLimit = 30

    /// The repositories with work, by name.
    var withWork: [RepositoryReview] {
        reviews.values.filter(\.hasWork)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func load(_ bookmarks: [RepositoryBookmark], from library: RepositoryLibrary) async {
        isLoading = true
        defer { isLoading = false }
        let listed = Set(bookmarks.map(\.id))
        for id in reviews.keys where !listed.contains(id) { reviews[id] = nil }
        for bookmark in bookmarks {
            guard !Task.isCancelled else { return }
            await load(bookmark, from: library)
        }
    }

    func load(_ bookmark: RepositoryBookmark, from library: RepositoryLibrary) async {
        guard let access = try? library.access(to: bookmark) else {
            reviews[bookmark.id] = nil
            return
        }
        let (id, name, url) = (bookmark.id, bookmark.name, access.url)
        let review = await Task.detached(priority: .userInitiated) {
            try? await Self.read(at: url, id: id, name: name)
        }.value
        // Held until the read is done: the folder is only open while it is.
        withExtendedLifetime(access) {}
        reviews[bookmark.id] = review
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

    private nonisolated static func read(at url: URL, id: UUID, name: String) async throws -> RepositoryReview {
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
        return RepositoryReview(
            id: id, name: name, branch: branch, upstream: head?.upstream?.name,
            hasRemote: !snapshot.remotes.isEmpty, entries: entries, commits: commits,
            ahead: head?.upstream?.ahead ?? 0, behind: head?.upstream?.behind ?? 0
        )
    }
}
