import Foundation
import GitKit
import Observation

/// The network side of an open repository: the operation under way, and
/// the prompts and confirmations it needs.
@MainActor
@Observable
final class RemoteOperations {
    /// A network operation under way.
    struct Activity {
        let title: String
        let transfer: Transfer
        var progress: TransferProgress?
    }

    private(set) var activity: Activity?
    let credentials = CredentialBroker()
    var isConfirmingForcePush = false
    var isManagingRemotes = false

    fileprivate func begin(_ title: String, transfer: Transfer) {
        activity = Activity(title: title, transfer: transfer)
        Task { [weak self] in
            for await progress in transfer.progress {
                guard let self, self.activity?.transfer === transfer else { return }
                self.activity?.progress = progress
            }
        }
    }

    fileprivate func end() {
        activity = nil
    }

    func cancel() {
        activity?.transfer.cancel()
    }
}

/// A pull that stopped short of finishing, which the user needs to hear about.
private struct PullStoppedOnConflicts: LocalizedError {
    let paths: [String]

    var errorDescription: String? {
        let files = paths.count == 1 ? "“\(paths[0])”" : "\(paths.count) files"
        return "The pull merged with conflicts in \(files). Resolve them in the working copy, then commit the merge."
    }
}

extension RepositoryModel {
    /// The checked-out branch, when `HEAD` is on one with commits.
    var currentBranch: Branch? {
        snapshot?.branches.first { $0.isHead }
    }

    var hasRemotes: Bool {
        snapshot?.remotes.isEmpty == false
    }

    /// Fetches every remote, pruning remote branches that are gone.
    func fetch() async {
        await runRemote("Fetching") { repository, transfer in
            try await repository.fetch(credentials: CredentialStore.shared, transfer: transfer)
        }
    }

    func pull() async {
        await runRemote("Pulling") { repository, transfer in
            let result = try await repository.pull(credentials: CredentialStore.shared, transfer: transfer)
            if case .conflicts(let paths) = result {
                self.selection = .workingCopy
                throw PullStoppedOnConflicts(paths: paths)
            }
        }
    }

    /// Pushes the current branch, publishing it if it has no upstream yet.
    /// A forced push refuses if the remote moved since the last fetch.
    func push(force: Bool = false) async {
        await runRemote(force ? "Force Pushing" : "Pushing") { repository, transfer in
            try await repository.push(force: force, credentials: CredentialStore.shared, transfer: transfer)
        }
    }

    func cancelRemoteOperation() {
        remotes.cancel()
    }

    // MARK: Remote management

    func addRemote(named name: String, url: String) async {
        await perform { try await $0.addRemote(named: name, url: url) }
    }

    /// Renames a remote and changes its URL, doing only what changed.
    func editRemote(_ remote: Remote, name: String, url: String) async {
        await perform { repository in
            if url != remote.url {
                try await repository.setURL(url, ofRemote: remote.name)
            }
            if name != remote.name {
                try await repository.renameRemote(remote.name, to: name)
            }
        }
    }

    func removeRemote(_ remote: Remote) async {
        await perform { try await $0.removeRemote(named: remote.name) }
    }

    /// Runs one network operation at a time, with its progress shown and
    /// credentials asked for as the remote wants them.
    private func runRemote(
        _ title: String, _ operation: @escaping (Repository, Transfer) async throws -> Void
    ) async {
        guard remotes.activity == nil else { return }
        do {
            try await remotes.credentials.run {
                // A new transfer for each attempt: a finished one reports nothing.
                let transfer = Transfer()
                remotes.begin(title, transfer: transfer)
                try await operation(repository, transfer)
            }
        } catch is CancellationError {
            // Cancelled by the user, who knows.
        } catch {
            self.error = PresentedError(error)
        }
        remotes.end()
        await refresh()
    }
}
