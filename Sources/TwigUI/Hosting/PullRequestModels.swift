import Foundation
import GitKit
import Observation

/// A repository's pull requests as the list shows them: one filter, loaded
/// a page at a time as the list scrolls.
@MainActor
@Observable
final class PullRequestList {
    var filter: PullRequestFilter = .open
    private(set) var items: [PullRequest] = []
    private(set) var next: PageCursor?
    private(set) var isLoading = false
    private(set) var failure: String?
    /// Whether signing in again could fix the failure.
    private(set) var failureNeedsSignIn = false
    /// What the items were loaded for: remote, account and filter.
    private(set) var loadedKey: String?

    static func key(target: HostingTarget, account: HostingAccount, filter: PullRequestFilter) -> String {
        "\(target.remote)|\(target.remoteURL)|\(account.id)|\(filter.rawValue)"
    }

    /// Loads the first page, unless it is already loaded for the same
    /// remote, account and filter and `force` is not set.
    func load(target: HostingTarget, account: HostingAccount, service: any HostingService, force: Bool = false) async {
        let key = Self.key(target: target, account: account, filter: filter)
        guard force || key != loadedKey else { return }
        loadedKey = key
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.pullRequests(in: target.path, filter: filter, page: nil)
            guard loadedKey == key else { return }
            items = page.items
            next = page.next
            failure = nil
            failureNeedsSignIn = false
        } catch is CancellationError {
            loadedKey = nil
        } catch {
            guard loadedKey == key else { return }
            items = []
            next = nil
            show(error)
        }
    }

    /// Loads the next page, as the list's end comes into view.
    func loadMore(target: HostingTarget, service: any HostingService) async {
        guard let cursor = next, !isLoading, let key = loadedKey else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.pullRequests(in: target.path, filter: filter, page: cursor)
            guard loadedKey == key else { return }
            let known = Set(items.map(\.number))
            items += page.items.filter { !known.contains($0.number) }
            next = page.next
        } catch is CancellationError {
        } catch {
            show(error)
        }
    }

    /// Puts a changed pull request in place, as after a merge.
    func replace(_ pullRequest: PullRequest) {
        if let index = items.firstIndex(where: { $0.number == pullRequest.number }) {
            items[index] = pullRequest
        }
    }

    func invalidate() {
        loadedKey = nil
    }

    private func show(_ error: any Error) {
        failure = error.localizedDescription
        failureNeedsSignIn = (error as? HostingError)?.needsSignIn ?? false
    }
}

/// One pull request in full: itself, its commits and files, and its
/// conversation.
@MainActor
@Observable
final class PullRequestDetail {
    let number: Int
    private(set) var pullRequest: PullRequest?
    private(set) var commits: [PullRequestCommit] = []
    private(set) var files: [PullRequestFile] = []
    /// The changes worked out from fetched commits, which then stand in for
    /// the service's list of files, with their diffs.
    private(set) var localComparison: Comparison?
    private(set) var conversation: [PullRequestComment] = []
    private(set) var isLoading = false
    private(set) var failure: String?
    /// A part that failed while the rest loaded, such as files.
    private(set) var partialFailures: [String] = []
    /// Set while an action (comment, review, merge…) is under way.
    private(set) var isActing = false
    var actionFailure: String?

    init(number: Int) {
        self.number = number
    }

    func load(target: HostingTarget, service: any HostingService, repository: Repository) async {
        isLoading = true
        defer { isLoading = false }
        let path = target.path, number = number
        do {
            let pullRequest = try await service.pullRequest(in: path, number: number)
            self.pullRequest = pullRequest
            failure = nil
            partialFailures = []
            async let commits = Self.attempt { try await service.commits(in: path, number: number) }
            async let conversation = Self.attempt { try await service.conversation(in: path, number: number) }
            let local = await Self.localComparison(of: pullRequest, in: repository)
            localComparison = local
            if local == nil {
                switch await Self.attempt({ try await service.changedFiles(in: path, number: number) }) {
                case .success(let files): self.files = files
                case .failure(let error): partialFailures.append("Files: \(error.localizedDescription)")
                }
            }
            switch await commits {
            case .success(let commits): self.commits = commits
            case .failure(let error): partialFailures.append("Commits: \(error.localizedDescription)")
            }
            switch await conversation {
            case .success(let items): self.conversation = items
            case .failure(let error): partialFailures.append("Conversation: \(error.localizedDescription)")
            }
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Runs an action on the service, then reloads.
    func act(
        target: HostingTarget, service: any HostingService, repository: Repository,
        _ action: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        isActing = true
        actionFailure = nil
        defer { isActing = false }
        do {
            try await action()
        } catch is CancellationError {
            return false
        } catch {
            actionFailure = error.localizedDescription
            return false
        }
        await load(target: target, service: service, repository: repository)
        return true
    }

    private static func attempt<Value: Sendable>(_ work: @Sendable () async throws -> Value) async -> Result<Value, any Error> {
        do {
            return .success(try await work())
        } catch {
            return .failure(error)
        }
    }

    /// The change from where the head left the base to the head, when both
    /// commits have been fetched: what the pull request brings.
    static func localComparison(of pullRequest: PullRequest, in repository: Repository) async -> Comparison? {
        guard let headHex = pullRequest.head.sha, let baseHex = pullRequest.base.sha,
              let head = OID(hex: headHex), let base = OID(hex: baseHex),
              await repository.hasCommit(head), await repository.hasCommit(base),
              let mergeBase = try? await repository.mergeBase(base, head) else { return nil }
        return try? await repository.compare(mergeBase, head)
    }
}
