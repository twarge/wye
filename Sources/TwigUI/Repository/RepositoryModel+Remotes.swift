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
        var transfer: Transfer
        var progress: TransferProgress?
    }

    private(set) var activity: Activity?
    let credentials = CredentialBroker()
    let autostash = AutostashBroker()
    var isConfirmingForcePush = false
    var isManagingRemotes = false
    /// The remote sheet on screen: options, push to, remote branch and tag actions.
    var sheet: RemoteSheet?
    /// What the last operation wants the user to know.
    var notice: OperationNotice?

    fileprivate func begin(_ title: String, transfer: Transfer) {
        // A retry, after credentials or a stash, keeps the activity on
        // screen and follows its new transfer.
        if activity?.title == title {
            activity?.transfer = transfer
        } else {
            activity = Activity(title: title, transfer: transfer)
        }
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

/// A sheet a remote action asks for. Menus set `RemoteOperations.sheet`; the
/// repository window shows it.
enum RemoteSheet: Identifiable, Hashable {
    case pullOptions
    case fetchOptions
    /// Push a local branch, by full reference name, somewhere chosen.
    case pushTo(branch: String?)
    case editRemote(Remote)
    case renameRemote(Remote)
    case removeRemote(Remote)
    /// A remote branch, by full name (`refs/remotes/origin/topic`).
    case deleteRemoteBranch(String)
    case renameRemoteBranch(String)
    /// A tag, by full name, to delete on a remote.
    case deleteRemoteTag(String)

    var id: Self { self }
}

extension RepositoryModel {
    /// The checked-out branch, when `HEAD` is on one with commits.
    var currentBranch: Branch? {
        snapshot?.branches.first { $0.isHead }
    }

    var hasRemotes: Bool {
        snapshot?.remotes.isEmpty == false
    }

    var remoteNames: [String] {
        snapshot?.remotes.map(\.name) ?? []
    }

    /// The remote that remote actions use when the user does not choose one:
    /// the current branch's upstream remote, `origin`, or the only remote.
    var defaultRemoteName: String? {
        let names = remoteNames
        if let upstream = currentBranch?.upstream?.name,
           let remote = names.filter({ upstream.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return remote
        }
        return names.contains("origin") ? "origin" : names.count == 1 ? names.first : nil
    }

    var isTransferring: Bool {
        remotes.activity != nil
    }

    // MARK: Fetch

    /// Fetches every remote, pruning remote branches that are gone.
    func fetch() async {
        await fetch(remote: nil, prune: true, tags: .automatic)
    }

    /// Fetches one remote, or all of them, as the Fetch options say.
    func fetch(remote: String?, prune: Bool, tags: FetchTags) async {
        let title = remote.map { "Fetching “\($0)”" } ?? "Fetching"
        await runRemote(title) { repository, transfer, _ in
            try await repository.fetch(
                remote: remote, prune: prune, tags: tags, credentials: CredentialStore.shared, transfer: transfer
            )
        }
    }

    // MARK: Pull and sync

    /// How a pull with no mode chosen goes: the repository's own
    /// configuration, otherwise the app's setting.
    func defaultPullMode() async -> PullMode {
        await repository.configuredPullMode() ?? RemotePreferences.pullMode
    }

    /// Pulls the current branch's upstream, by `mode` or the default one.
    /// `autostash` chooses whether to stash local changes first, in place
    /// of the setting.
    func pull(mode: PullMode? = nil, autostash: Bool? = nil) async {
        let mode = await resolvedMode(mode)
        await runRemote("Pulling", autostashes: true, autostash: autostash) { repository, transfer, autostash in
            let outcome = try await repository.pull(
                options: PullOptions(mode: mode, autostash: autostash),
                credentials: CredentialStore.shared, transfer: transfer
            )
            self.report(outcome, action: "Pull")
        }
    }

    /// Pulls a remote branch, by full name, into the current branch.
    func pull(remoteBranch: String, mode: PullMode? = nil, autostash: Bool? = nil) async {
        let mode = await resolvedMode(mode)
        await runRemote("Pulling", autostashes: true, autostash: autostash) { repository, transfer, autostash in
            let outcome = try await repository.pull(
                from: remoteBranch, options: PullOptions(mode: mode, autostash: autostash),
                credentials: CredentialStore.shared, transfer: transfer
            )
            self.report(outcome, action: "Pull")
        }
    }

    /// Pulls, then pushes what the pull left, as one operation.
    func sync() async {
        let mode = await resolvedMode(nil)
        await runRemote("Syncing", autostashes: true) { repository, transfer, autostash in
            let result = try await repository.sync(
                options: PullOptions(mode: mode, autostash: autostash),
                credentials: CredentialStore.shared, transfer: transfer
            )
            self.report(result.pull, action: "Sync", stoppedBeforePushing: result.push == nil)
        }
    }

    private func resolvedMode(_ mode: PullMode?) async -> PullMode {
        if let mode { return mode }
        return await defaultPullMode()
    }

    private func report(_ outcome: PullOutcome, action: String, stoppedBeforePushing: Bool = false) {
        let pushNote = stoppedBeforePushing ? " Nothing was pushed." : ""
        let stopped: String? = switch outcome.result {
        case .conflicts(let paths):
            "The pull merged with conflicts in \(Self.describe(paths)). Resolve them in the working copy, "
                + "then commit the merge.\(pushNote)"
        case .rebaseStopped(_, let paths):
            "The rebase stopped on conflicts in \(Self.describe(paths)). Resolve them in the working copy, "
                + "then continue the rebase.\(pushNote)"
        case .upToDate, .fastForwarded, .merged, .rebased:
            nil
        }
        if stopped != nil {
            selection = .workingCopy
        }
        report(outcome.autostash, after: action, stoppedReason: stopped)
    }

    // MARK: Push

    /// Pushes the current branch, publishing it if it has no upstream yet.
    /// A forced push refuses if the remote moved since the last fetch.
    func push(force: Bool = false) async {
        await runRemote(force ? "Force Pushing" : "Pushing") { repository, transfer, _ in
            try await repository.push(force: force, credentials: CredentialStore.shared, transfer: transfer)
        }
    }

    /// Pushes a local branch to a chosen remote and branch name.
    func push(branch: String, to remote: String, as remoteBranch: String, setUpstream: Bool) async {
        await runRemote("Pushing") { repository, transfer, _ in
            try await repository.push(
                branch: branch, to: remote, as: remoteBranch, setUpstream: setUpstream,
                credentials: CredentialStore.shared, transfer: transfer
            )
        }
    }

    // MARK: Tags on remotes

    func pushTag(_ tag: String, to remote: String) async {
        await runRemote("Pushing Tag") { repository, transfer, _ in
            try await repository.pushTags([tag], to: remote, credentials: CredentialStore.shared, transfer: transfer)
        }
    }

    func pushAllTags(to remote: String) async {
        await runRemote("Pushing Tags") { repository, transfer, _ in
            try await repository.pushAllTags(to: remote, credentials: CredentialStore.shared, transfer: transfer)
        }
    }

    func deleteRemoteTag(_ tag: String, on remote: String) async {
        await runRemote("Deleting Tag") { repository, transfer, _ in
            try await repository.deleteRemoteTag(tag, on: remote, credentials: CredentialStore.shared, transfer: transfer)
        }
    }

    // MARK: Branches on remotes

    func deleteRemoteBranch(_ id: String) async {
        await runRemote("Deleting Branch") { repository, transfer, _ in
            try await repository.deleteRemoteBranch(id, credentials: CredentialStore.shared, transfer: transfer)
            if self.selection == .remoteBranch(id) {
                self.selection = .history
            }
        }
    }

    func renameRemoteBranch(_ id: String, to name: String) async {
        await runRemote("Renaming Branch") { repository, transfer, _ in
            let renamed = try await repository.renameRemoteBranch(
                id, to: name, credentials: CredentialStore.shared, transfer: transfer
            )
            if self.selection == .remoteBranch(id) {
                self.selection = .remoteBranch(renamed)
            }
        }
    }

    func cancelRemoteOperation() {
        remotes.cancel()
    }

    // MARK: Remote management

    func addRemote(named name: String, url: String, pushURL: String? = nil) async {
        await perform { repository in
            try await repository.addRemote(named: name, url: url)
            if let pushURL, !pushURL.isEmpty {
                try await repository.setPushURL(pushURL, ofRemote: name)
            }
        }
    }

    /// Renames a remote and changes its URLs, doing only what changed.
    /// `pushURL` is `nil` to leave the push URL alone, empty to clear it.
    func editRemote(_ remote: Remote, name: String, url: String, pushURL: String? = nil) async {
        await perform { repository in
            if url != remote.url ?? "" {
                try await repository.setURL(url, ofRemote: remote.name)
            }
            if let pushURL, try await repository.pushURL(ofRemote: remote.name) ?? "" != pushURL {
                try await repository.setPushURL(pushURL, ofRemote: remote.name)
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
    /// credentials asked for as the remote wants them. An operation that
    /// `autostashes` is told whether to set local changes aside: from the
    /// start when the setting says always, or after asking when they turn
    /// out to be in its way.
    private func runRemote(
        _ title: String,
        autostashes: Bool = false,
        autostash: Bool? = nil,
        _ operation: @escaping (Repository, Transfer, Bool) async throws -> Void
    ) async {
        guard remotes.activity == nil else { return }
        // A choice made for this operation stands; there is nothing to ask.
        let policy = autostash == nil ? RemotePreferences.autostash : .never
        var stashing = autostashes && (autostash ?? (policy == .always))
        do {
            while true {
                do {
                    try await remotes.credentials.run {
                        // A new transfer for each attempt: a finished one reports nothing.
                        let transfer = Transfer()
                        remotes.begin(title, transfer: transfer)
                        try await operation(repository, transfer, stashing)
                    }
                    break
                } catch let error as GitError
                            where autostashes && !stashing && policy == .ask && error.isBlockedByLocalChanges {
                    guard try await repository.hasChangesToTrackedFiles(),
                          await remotes.autostash.ask(Self.actionName(of: title)) else { throw error }
                    stashing = true
                }
            }
        } catch is CancellationError {
            // Cancelled by the user, who knows.
        } catch {
            self.error = PresentedError(error)
        }
        remotes.end()
        await refresh()
    }

    /// "Pull" for "Pulling": the name a question about it uses.
    private static func actionName(of title: String) -> String {
        switch title {
        case "Pulling": "Pull"
        case "Syncing": "Sync"
        default: title
        }
    }
}
