import Foundation
import GitKit

/// A pull request that asks the signed-in account for review, as the Review
/// lists it.
struct ReviewRequest: Identifiable, Hashable, Sendable {
    /// `host/owner/project`: the repository it is on.
    var repository: String
    var kind: HostingKind
    var number: Int
    var title: String
    /// Who opened it, by login.
    var author: String?
    var isDraft = false
    var updatedAt: Date?
    var webURL: URL?

    var id: String { "\(repository)#\(number)" }

    /// `#12`, or `!12` for a GitLab merge request.
    var reference: String { kind.reference(number) }

    /// Whether `query` is in its title, its number or its author's name.
    func matches(_ query: String) -> Bool {
        title.localizedStandardContains(query) || reference.localizedStandardContains(query)
            || author?.localizedStandardContains(query) == true
    }
}

extension ReviewRequest {
    init(_ pullRequest: PullRequest, in source: ReviewRequestSource) {
        self.init(
            repository: source.key, kind: source.kind, number: pullRequest.number, title: pullRequest.title,
            author: pullRequest.author?.login, isDraft: pullRequest.isDraft, updatedAt: pullRequest.updatedAt,
            webURL: pullRequest.webURL
        )
    }
}

/// A repository on a hosting service, and the account that asks it which
/// pull requests wait for review.
struct ReviewRequestSource: Identifiable, Sendable {
    /// `host/owner/project`, the same for every address of the repository.
    var key: String
    var kind: HostingKind
    var path: RepositoryPath
    var accountID: UUID
    var service: any HostingService

    /// The repository and who asks: what its answer is kept by, since
    /// another account is asked for other reviews.
    var id: String { key + "|" + accountID.uuidString }
}

/// The pull requests that wait for the signed-in accounts' review, for the
/// Review: asked of each repository's hosting service, a few requests at a
/// time, and kept for a while so that reading the repositories again does
/// not ask again. Several listed folders of one repository share an answer.
///
/// The Review is whole without them, so a service that cannot be asked (no
/// account, no network, too many requests) is left alone for a while and
/// nothing is said: what it last answered, if anything, stands.
@MainActor
final class ReviewRequests {
    static let shared = ReviewRequests()

    /// What a repository's services said.
    struct Answer: Hashable, Sendable {
        var requests: [ReviewRequest] = []
        /// Whether a service has more than were read.
        var hasMore = false

        /// No pull request waits, or none is known of.
        static let none = Answer()
    }

    private struct Kept {
        var answer: Answer
        var heardAt: Date
    }

    /// By source.
    private var kept: [String: Kept] = [:]
    /// The requests under way, by source: a second asker waits for the first.
    private var asking: [String: Task<Void, Never>] = [:]
    /// Until when a source, by its id, or everything an account asks, by
    /// the account's id, is left alone after a failure.
    private var heldOff: [String: Date] = [:]
    /// How many more requests may start now, and the ones waiting to.
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// See `accountsChanged(to:)`.
    private var accountChangesSeen: Int?

    private let accounts: AccountStore
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    /// How long an answer stands before its service is asked again, in seconds.
    nonisolated static let lifetime: TimeInterval = 10 * 60
    /// The same when the user asks for the Review to be read again.
    nonisolated static let lifetimeWhenAskedAgain: TimeInterval = 15
    /// How many services are asked at once, however many repositories are listed.
    nonisolated static let concurrentRequests = 4
    /// How many pages of a repository's pull requests are read. Gitea and
    /// Forgejo are sent every open one and the ones to review are picked
    /// out here, so theirs may not be on the first page.
    nonisolated static let pageLimit = 3

    init(
        accounts: AccountStore = .shared, transport: any HTTPTransport = URLSessionTransport(),
        concurrentRequests: Int = ReviewRequests.concurrentRequests, now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.accounts = accounts
        self.transport = transport
        self.now = now
        free = max(1, concurrentRequests)
    }

    // MARK: Asking

    /// The pull requests that wait for review on the services a
    /// repository's remotes are on: the answers kept, or the services'
    /// when those are missing or have aged. Empty where no account is
    /// signed in for them, and where they could not be asked and never
    /// answered before.
    ///
    /// - Parameter asksAgain: Whether to ask whatever was heard lately.
    func reviewRequests(for remotes: [Remote], asksAgain: Bool = false) async -> Answer {
        var answer = Answer()
        for source in await sources(for: remotes) {
            await refresh(source, asksAgain: asksAgain)
            guard let kept = kept[source.id] else { continue }
            answer.requests += kept.answer.requests
            answer.hasMore = answer.hasMore || kept.answer.hasMore
        }
        return answer
    }

    /// The repositories to ask about for a folder's remotes, each with an
    /// account that can ask: `upstream` and `origin`, since a copy's pull
    /// requests are opened on the repository it was copied from, or else
    /// the first remote on a service Wye knows.
    func sources(for remotes: [Remote]) async -> [ReviewRequestSource] {
        let (accounts, transport) = (accounts, transport)
        // Off the main thread: the first reading of the accounts opens the Keychain.
        return await Task.detached(priority: .utility) {
            Self.sources(for: remotes, accounts: accounts, transport: transport)
        }.value
    }

    nonisolated static func sources(
        for remotes: [Remote], accounts: AccountStore, transport: any HTTPTransport
    ) -> [ReviewRequestSource] {
        // Reading the accounts tells which service each self-hosted account's host runs.
        _ = try? accounts.accounts()
        let targets = HostingTarget.targets(for: remotes)
        let named = targets.filter { $0.remote == "upstream" || $0.remote == "origin" }
        var seen: Set<String> = []
        return (named.isEmpty ? Array(targets.prefix(1)) : named).compactMap { target in
            let key = target.hosted.key
            guard !seen.contains(key), let account = target.account(in: accounts),
                  let service = try? account.service(store: accounts, transport: transport) else { return nil }
            seen.insert(key)
            return ReviewRequestSource(
                key: key, kind: target.kind, path: target.path, accountID: account.id, service: service
            )
        }
    }

    /// Asks a source unless its answer is recent or it is being left alone,
    /// and returns once it has answered or failed.
    private func refresh(_ source: ReviewRequestSource, asksAgain: Bool) async {
        guard isDue(source, asksAgain: asksAgain) else { return }
        if let task = asking[source.id] {
            await task.value
            return
        }
        let task = Task {
            await enter()
            // An earlier request may have found the account refused while this one waited.
            if !isHeldOff(source) {
                do {
                    kept[source.id] = Kept(answer: try await Self.ask(source), heardAt: now())
                } catch is CancellationError {
                } catch {
                    holdOff(source, after: error)
                }
            }
            asking[source.id] = nil
            leave()
        }
        asking[source.id] = task
        await task.value
    }

    private func isDue(_ source: ReviewRequestSource, asksAgain: Bool) -> Bool {
        guard !isHeldOff(source) else { return false }
        guard let kept = kept[source.id] else { return true }
        return now().timeIntervalSince(kept.heardAt) >= (asksAgain ? Self.lifetimeWhenAskedAgain : Self.lifetime)
    }

    /// Reads the pull requests that ask the source's account for review, a
    /// few pages at most.
    nonisolated static func ask(_ source: ReviewRequestSource) async throws -> Answer {
        var answer = Answer()
        var seen: Set<Int> = []
        var cursor: PageCursor?
        for _ in 0..<pageLimit {
            let page = try await source.service.pullRequests(in: source.path, filter: .reviewRequested, page: cursor)
            for pullRequest in page.items where seen.insert(pullRequest.number).inserted {
                answer.requests.append(ReviewRequest(pullRequest, in: source))
            }
            cursor = page.next
            if cursor == nil { break }
        }
        answer.hasMore = cursor != nil
        return answer
    }

    // MARK: A few at a time

    /// Waits for one of the few requests allowed at once.
    private func enter() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Lets the next request waiting start.
    private func leave() {
        if waiting.isEmpty {
            free += 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: Failures

    private func isHeldOff(_ source: ReviewRequestSource) -> Bool {
        let date = now()
        return [source.id, source.accountID.uuidString].contains { key in
            heldOff[key].map { $0 > date } ?? false
        }
    }

    /// Leaves a source alone for a while after it failed, and everything
    /// its account asks where the failure is the account's or the
    /// network's: the next repository would only fail the same way.
    private func holdOff(_ source: ReviewRequestSource, after error: any Error) {
        let date = now()
        let account = source.accountID.uuidString
        switch error as? HostingError {
        case .offline:
            heldOff[account] = date.addingTimeInterval(30)
        case .rateLimited(_, let reset):
            heldOff[account] = date.addingTimeInterval(max(60, reset.map { $0.timeIntervalSince(date) } ?? 5 * 60))
        case .unauthorized, .noAccount:
            heldOff[account] = date.addingTimeInterval(15 * 60)
        case .forbidden, .notFound, .unsupported, .rejected:
            // This repository's alone: the account may not see it, or its service has no such list.
            heldOff[source.id] = date.addingTimeInterval(15 * 60)
        default:
            heldOff[source.id] = date.addingTimeInterval(2 * 60)
        }
    }

    /// Takes how many times the accounts have changed, as
    /// `AccountChangeCounter` counts them. When that is more than it was,
    /// the services that failed are asked again: an account was added, or
    /// signed in again, and may be let in now.
    func accountsChanged(to count: Int) {
        if let seen = accountChangesSeen, seen != count { heldOff = [:] }
        accountChangesSeen = count
    }
}
