import AppIntents
import Foundation
import GitKit

extension RepositoryLibrary {
    /// The one list of repositories in the app's process, shared by its
    /// windows and its intents so that neither saves over the other.
    static let shared = RepositoryLibrary()
}

/// An intent's failure, said as one sentence.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Runs the repository intents: outside any window, without asking the
/// user anything, one operation per repository at a time.
@MainActor
enum RepositoryIntentRunner {
    /// Repositories an intent is working on, with what it is doing.
    private static var running: [UUID: String] = [:]

    private static var library: RepositoryLibrary { .shared }

    static func bookmark(for id: UUID) throws -> RepositoryBookmark {
        guard let bookmark = library.bookmarks.first(where: { $0.id == id }) else {
            throw IntentFailure(message: "That repository is no longer in Wye.")
        }
        return bookmark
    }

    /// Opens the repository and runs `body` on it, refusing while a window
    /// or another intent is busy with it. Failures come out as sentences.
    static func run<Result>(
        _ title: String, on id: UUID, _ body: (Repository, RepositoryBookmark) async throws -> Result
    ) async throws -> Result {
        let bookmark = try bookmark(for: id)
        if let activity = OpenRepositories.activity(for: id) ?? running[id] {
            throw IntentFailure(message: IntentPhrasing.busy(bookmark.name, activity: activity))
        }
        running[id] = title
        defer { running[id] = nil }
        // The app may have been launched just for this intent, before any
        // window set up the app's own git configuration.
        try? GitEnvironment.useGlobalConfiguration(in: .applicationSupportDirectory.appending(path: "Twig/git"))
        do {
            let access = try library.access(to: bookmark)
            defer { withExtendedLifetime(access) {} }
            let repository = try Repository(at: access.url)
            let result = try await body(repository, bookmark)
            for model in OpenRepositories.models(for: id) {
                await model.refresh()
            }
            // So the widget shows what the intent did.
            if let summary = try? await RepositoryStatusSummary.read(from: repository, id: id, name: bookmark.name) {
                RepositoryStatusBoard.shared.record(summary)
            }
            return result
        } catch let error as IntentFailure {
            throw error
        } catch {
            throw IntentFailure(message: IntentPhrasing.failure(error, name: bookmark.name))
        }
    }

    // MARK: Operations

    /// The current branch's name, or a failure saying there is none.
    private static func branchName(of repository: Repository) async throws -> String {
        guard case .branch(let reference, _) = try await repository.head() else { throw RemoteError.notOnBranch }
        return reference.hasPrefix("refs/heads/") ? String(reference.dropFirst("refs/heads/".count)) : reference
    }

    static func pull(_ id: UUID) async throws -> String {
        try await run("Pulling", on: id) { repository, _ in
            let branch = try await branchName(of: repository)
            let before = try await repository.head().target
            let mode = await repository.configuredPullMode() ?? RemotePreferences.pullMode
            // Asking whether to stash is not possible here, so only the
            // setting that says always does it.
            let outcome = try await repository.pull(
                options: PullOptions(mode: mode, autostash: RemotePreferences.autostash == .always),
                credentials: CredentialStore.shared
            )
            let count = if let before { try await repository.headCommitCount(notIn: before) } else { 0 }
            return IntentPhrasing.pulled(outcome, count: count, branch: branch)
        }
    }

    static func fetch(_ id: UUID) async throws -> String {
        try await run("Fetching", on: id) { repository, bookmark in
            try await repository.fetch(prune: true, credentials: CredentialStore.shared)
            let snapshot = try await repository.snapshot()
            return IntentPhrasing.fetched(bookmark.name, branch: snapshot.branches.first(where: \.isHead))
        }
    }

    static func push(_ id: UUID) async throws -> String {
        try await run("Pushing", on: id) { repository, _ in
            let branch = try await branchName(of: repository)
            let upstream = try await repository.snapshot().branches.first(where: \.isHead)?.upstream
            if let upstream, upstream.ahead == 0 {
                return IntentPhrasing.nothingToPush(branch: branch)
            }
            let result = try await repository.push(
                includingTags: RepositoryPreferences.resolvedPushesAllTags(for: id), credentials: CredentialStore.shared
            )
            return IntentPhrasing.pushed(result, branch: branch, count: upstream?.ahead ?? 0)
        }
    }

    static func status(_ id: UUID) async throws -> RepositoryStatusEntity {
        try await run("Reading", on: id) { repository, bookmark in
            let snapshot = try await repository.snapshot()
            let changed = try await repository.status().count
            let head = snapshot.branches.first(where: \.isHead)
            let branch: String? = if case .unborn(let name) = snapshot.head {
                name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
            } else {
                head?.name
            }
            let status = RepositoryStatusEntity()
            status.name = bookmark.name
            status.branch = branch
            status.ahead = head?.upstream?.ahead ?? 0
            status.behind = head?.upstream?.behind ?? 0
            status.changedFiles = changed
            status.summary = IntentPhrasing.status(
                bookmark.name, branch: branch, upstream: head?.upstream, changedFiles: changed
            )
            return status
        }
    }

    /// Fetches every listed repository with a remote, one after another.
    static func fetchAll() async -> String {
        var succeeded = 0
        var failures: [String] = []
        for bookmark in library.listedBookmarks {
            do {
                let fetched = try await run("Fetching", on: bookmark.id) { repository, _ in
                    // One with no remotes has nothing to fetch, which is not a failure.
                    guard try await !repository.snapshot().remotes.isEmpty else { return false }
                    try await repository.fetch(prune: true, credentials: CredentialStore.shared)
                    return true
                }
                if fetched { succeeded += 1 }
            } catch let failure as IntentFailure {
                failures.append(failure.message)
            } catch {
                failures.append(IntentPhrasing.failure(error, name: bookmark.name))
            }
        }
        return IntentPhrasing.fetchedAll(succeeded: succeeded, failures: failures)
    }
}
