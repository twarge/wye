import Foundation
import GitKit
import Observation

/// A remote on a hosting service Wye can talk to.
struct HostingTarget: Hashable, Identifiable {
    var remote: String
    var remoteURL: String
    var hosted: HostedRepository
    var kind: HostingKind
    var path: RepositoryPath

    var id: String { remote }

    /// Whether the remote is reached over SSH, so new remotes match it.
    var usesSSH: Bool {
        !remoteURL.lowercased().hasPrefix("http")
    }
}

/// A sheet the hosting features ask the repository window for.
enum HostingSheet: Identifiable, Hashable {
    /// Publish to an account of this service, or any.
    case publish(HostingKind?)
    /// A new pull request from a local branch, by full reference name.
    case newPullRequest(head: String?)
    /// Which account a remote uses.
    case account(remote: String)

    var id: Self { self }
}

/// A repository window's hosting state: the pull request list and detail,
/// and the sheet on screen.
@MainActor
@Observable
final class HostingState {
    var sheet: HostingSheet?
    /// The remote whose pull requests are listed, when the user chose one.
    var chosenRemote: String?
    let pullRequests = PullRequestList()
    var selectedPullRequest: Int?
    /// The selected pull request's detail, kept while it stays selected.
    var detail: PullRequestDetail?

    init() {
        // Reading the accounts once tells the web links which service each
        // self-hosted account's host runs.
        _ = try? AccountStore.shared.accounts()
    }

    /// Makes the detail for a pull request, unless it is the one shown.
    func showDetail(for number: Int) {
        if detail?.number != number {
            detail = PullRequestDetail(number: number)
        }
    }
}

/// What pull requests can be shown with, or why they cannot.
enum HostingAvailability {
    case ready(HostingTarget, HostingAccount, any HostingService)
    /// No remote is on a service Wye knows.
    case noHostedRemote
    /// The remote's service is known but no account can use it.
    case noAccount(HostingTarget)

    var message: String? {
        switch self {
        case .ready: nil
        case .noHostedRemote:
            "None of this repository’s remotes is on GitHub, GitLab, Bitbucket, Gitea or Forgejo. "
                + "A self-hosted service is known once an account for its host is added in Settings."
        case .noAccount(let target):
            "Sign in to \(target.kind.title) on \(target.hosted.host) in Settings, under Accounts, "
                + "to see \(target.kind.pullRequestTerm.lowercased())s here."
        }
    }
}

extension RepositoryModel {
    /// The remotes on a known service, `upstream` and `origin` first.
    var hostingTargets: [HostingTarget] {
        let remotes = snapshot?.remotes ?? []
        let targets = remotes.compactMap { remote -> HostingTarget? in
            guard let url = remote.url, let hosted = HostedRepository(remoteURL: url),
                  let kind = HostingKind(hosted.kind), let path = hosted.repositoryPath else { return nil }
            return HostingTarget(remote: remote.name, remoteURL: url, hosted: hosted, kind: kind, path: path)
        }
        let order = ["upstream": 0, "origin": 1]
        return targets.sorted { (order[$0.remote] ?? 2, $0.remote) < (order[$1.remote] ?? 2, $1.remote) }
    }

    /// The remote pull requests are listed for: the one chosen, else
    /// `upstream` (where a contribution's pull requests go), else `origin`.
    var pullRequestTarget: HostingTarget? {
        let targets = hostingTargets
        if let chosen = hosting.chosenRemote, let target = targets.first(where: { $0.remote == chosen }) {
            return target
        }
        return targets.first
    }

    /// The account a remote's API requests use: the repository's choice
    /// or the host's default, where it can use the service, else any
    /// account for the host that can.
    func hostingAccount(for target: HostingTarget) -> HostingAccount? {
        let store = AccountStore.shared
        if let account = store.account(forRemoteURL: target.remoteURL), account.usesService {
            return account
        }
        return store.accounts(forHost: target.hosted.host).first { $0.usesService && $0.kind == target.kind }
    }

    func hostingAvailability(for target: HostingTarget? = nil) -> HostingAvailability {
        guard let target = target ?? pullRequestTarget else { return .noHostedRemote }
        guard let account = hostingAccount(for: target), let service = try? account.service() else {
            return .noAccount(target)
        }
        return .ready(target, account, service)
    }

    // MARK: Publish

    /// Makes a repository on the account's service and adds it as a
    /// remote: `origin` unless that is taken. Throws, saying what was done,
    /// if either step fails. Then `pushPublished` pushes to it.
    func createPublishedRemote(_ draft: NewRepositoryDraft, on account: HostingAccount, preferSSH: Bool) async throws -> PublishedRemote {
        let service = try account.service()
        let created = try await service.createRepository(draft)
        let url = created.cloneURL(preferSSH: preferSSH)
        let names = remoteNames
        let remote = !names.contains("origin") ? "origin"
            : [account.kind?.rawValue ?? "hosted", "published"].first { !names.contains($0) } ?? "published-\(names.count)"
        do {
            try await repository.addRemote(named: remote, url: url)
        } catch {
            throw PublishError.remoteNotAdded(created.webURL ?? URL(string: created.httpsURL), error)
        }
        if AccountStore.shared.defaultAccount(forHost: account.host)?.id != account.id {
            AccountStore.shared.setAccount(account.id, forRemoteURL: url)
        }
        await refresh()
        return PublishedRemote(remote: remote, page: created.webURL?.absoluteString ?? url, path: created.path)
    }

    /// Pushes the current branch to a remote Publish made, tracking it. A
    /// failed push says the repository and remote are there already.
    func pushPublished(_ published: PublishedRemote) async {
        guard let branch = currentBranch else {
            remotes.notice = OperationNotice(
                title: "Published",
                message: "\(published.path) was made and added as “\(published.remote)”. There are no commits to push yet."
            )
            return
        }
        let includingTags = pushesAllTags
        await runRemote("Publishing") { repository, transfer, _ in
            do {
                let result = try await repository.push(
                    branch: branch.id, to: published.remote, as: nil, setUpstream: true, includingTags: includingTags,
                    credentials: CredentialStore.shared, transfer: transfer
                )
                self.reportRejectedTags(of: result)
            } catch let error as RemoteError where error.credentialHost != nil || HostKeyPrompt(error) != nil
                        || SSHKeyPrompt(error) != nil {
                // The broker asks and runs the push again.
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PublishError.notPushed(remote: published.remote, page: published.page, error)
            }
        }
    }

    // MARK: Fetch

    /// Fetches a pull request's base and head commits without making any
    /// branch or remote, so its changes can be worked out here. Refspecs
    /// without a destination keep the commits and touch no reference
    /// but `FETCH_HEAD`.
    func fetchPullRequestCommits(_ pullRequest: PullRequest, target: HostingTarget, service: any HostingService) async {
        var fromTarget = ["refs/heads/\(pullRequest.base.name)"]
        var fromHead: (url: String, refspec: String)?
        if let reference = service.headReference(number: pullRequest.number) {
            fromTarget.append(reference)
        } else if !pullRequest.isFromOtherRepository {
            fromTarget.append("refs/heads/\(pullRequest.head.name)")
        } else if let repository = pullRequest.head.repository,
                  let url = target.usesSSH ? (repository.sshURL ?? repository.httpsURL) : (repository.httpsURL ?? repository.sshURL) {
            fromHead = (url, "refs/heads/\(pullRequest.head.name)")
        }
        let refspecs = fromTarget
        await runRemote("Fetching \(target.kind.reference(pullRequest.number))") { repository, transfer, _ in
            try await repository.fetch(refspecs: refspecs, from: target.remote, credentials: CredentialStore.shared, transfer: transfer)
        }
        if let fromHead {
            await runRemote("Fetching \(target.kind.reference(pullRequest.number))") { repository, transfer, _ in
                try await repository.fetch(
                    refspecs: [fromHead.refspec], from: fromHead.url, credentials: CredentialStore.shared, transfer: transfer
                )
            }
        }
    }

    // MARK: Check out

    /// Fetches a pull request's head into a local branch that tracks it,
    /// and checks that out. A head on another repository gets a remote
    /// named after its owner; when that repository is gone, the base's
    /// pull request reference is fetched into a branch of its own.
    func checkOutPullRequest(_ pullRequest: PullRequest, target: HostingTarget, service: any HostingService) async {
        // Lists leave out some of the head's repository on some services.
        let pullRequest = (try? await service.pullRequest(in: target.path, number: pullRequest.number)) ?? pullRequest
        let plan = PullRequestCheckout.plan(
            for: pullRequest, target: target, remotes: snapshot?.remotes ?? [], branches: snapshot?.branches ?? [],
            headReference: service.headReference(number: pullRequest.number)
        )
        guard let plan else {
            error = PresentedError(HostingError.unsupported(
                "The repository this \(target.kind.pullRequestTerm.lowercased()) comes from cannot be reached, "
                    + "and \(target.kind.title) has no reference for its head on \(target.path)."
            ))
            return
        }
        var fetched = false
        await runRemote("Fetching \(target.kind.reference(pullRequest.number))") { repository, transfer, _ in
            if let remote = plan.addRemote, try await !repository.snapshot().remotes.contains(where: { $0.name == remote.name }) {
                try await repository.addRemote(named: remote.name, url: remote.url)
            }
            try await repository.fetch(
                refspecs: [plan.refspec], from: plan.fetchFrom, credentials: CredentialStore.shared, transfer: transfer
            )
            fetched = true
        }
        guard fetched else { return }
        if plan.tracks {
            await trackRemoteBranch(plan.fetchedReference, named: plan.localName, checkOut: true)
        } else {
            await perform(.checkout) { repository in
                let commit = try await repository.resolveRevision(plan.fetchedReference)
                let local = try await repository.createBranch(named: plan.localName, at: commit)
                try await self.withAutostash("Check Out") { try $0.checkOut(branch: local) }
                self.selection = .branch(local)
            }
        }
    }
}

/// How a pull request's head is fetched and checked out.
struct PullRequestCheckout: Hashable {
    struct NewRemote: Hashable {
        var name: String
        var url: String
    }

    /// A remote to add first, for a head on another repository.
    var addRemote: NewRemote?
    /// The remote's name, or a URL, to fetch from.
    var fetchFrom: String
    var refspec: String
    /// Where the fetch puts the head: `refs/remotes/mona/topic`.
    var fetchedReference: String
    var localName: String
    /// Whether the local branch tracks the fetched one. A head fetched from
    /// the base's pull request reference has no branch to track.
    var tracks: Bool

    static func plan(
        for pullRequest: PullRequest, target: HostingTarget, remotes: [Remote], branches: [Branch],
        headReference: String?
    ) -> PullRequestCheckout? {
        let head = pullRequest.head.name
        let headRepository = pullRequest.head.repository
        // A head whose repository is not said is fetched by the pull
        // request's own reference where there is one, not guessed at.
        // One said to be there without a path is gone.
        let sameRepository = if headRepository?.path != nil {
            !pullRequest.isFromOtherRepository
        } else {
            headRepository == nil && headReference == nil
        }
        if sameRepository, !head.isEmpty {
            let fetched = "refs/remotes/\(target.remote)/\(head)"
            return PullRequestCheckout(
                addRemote: nil, fetchFrom: target.remote, refspec: "+refs/heads/\(head):\(fetched)",
                fetchedReference: fetched, localName: localName(head, owner: nil, remote: target.remote, branches: branches),
                tracks: true
            )
        }
        if let path = headRepository?.path, !head.isEmpty,
           let url = target.usesSSH ? (headRepository?.sshURL ?? headRepository?.httpsURL) : (headRepository?.httpsURL ?? headRepository?.sshURL) {
            // A remote that is already this repository, by any address, is used as it is.
            let key = HostedRepository(remoteURL: url)?.key
            let existing = remotes.first { remote in
                remote.url.flatMap(HostedRepository.init(remoteURL:))?.key == key
            }
            let owner = path.owner.split(separator: "/").last.map(String.init) ?? path.owner
            let name = existing?.name ?? uniqueRemoteName(owner, remotes: remotes)
            let fetched = "refs/remotes/\(name)/\(head)"
            return PullRequestCheckout(
                addRemote: existing == nil ? NewRemote(name: name, url: url) : nil,
                fetchFrom: name, refspec: "+refs/heads/\(head):\(fetched)", fetchedReference: fetched,
                localName: localName(head, owner: owner, remote: name, branches: branches), tracks: true
            )
        }
        guard let headReference else { return nil }
        let fetched = "refs/remotes/\(target.remote)/pr/\(pullRequest.number)"
        var local = "pr/\(pullRequest.number)"
        var suffix = 2
        while branches.contains(where: { $0.name == local }) {
            local = "pr/\(pullRequest.number)-\(suffix)"
            suffix += 1
        }
        return PullRequestCheckout(
            addRemote: nil, fetchFrom: target.remote, refspec: "+\(headReference):\(fetched)",
            fetchedReference: fetched, localName: local, tracks: false
        )
    }

    /// The head's own name, unless a local branch of that name tracks
    /// something else: then `owner/head`, or `pr/head`.
    private static func localName(_ head: String, owner: String?, remote: String, branches: [Branch]) -> String {
        func isFree(_ name: String) -> Bool {
            guard let branch = branches.first(where: { $0.name == name }) else { return true }
            // A branch that already tracks it is used again.
            return branch.upstream?.name == "\(remote)/\(head)"
        }
        let candidates = [head, owner.map { "\($0)/\(head)" }, "pr/\(head)"].compactMap { $0 }
        return candidates.first(where: isFree) ?? head
    }

    private static func uniqueRemoteName(_ owner: String, remotes: [Remote]) -> String {
        let names = Set(remotes.map(\.name))
        let base = owner.isEmpty ? "contributor" : owner
        var name = base
        var suffix = 2
        while names.contains(name) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        return name
    }
}

/// A repository Publish made and the remote it was added as.
struct PublishedRemote: Hashable {
    var remote: String
    /// Its page, or its URL where the service gave no page.
    var page: String
    var path: RepositoryPath
}

/// What went wrong after a repository was made on the service.
enum PublishError: LocalizedError {
    case remoteNotAdded(URL?, any Error)
    case notPushed(remote: String, page: String, any Error)

    var errorDescription: String? {
        switch self {
        case .remoteNotAdded(let url, let error):
            "The repository was made\(url.map { " at \($0.absoluteString)" } ?? ""), but Wye could not add it as a remote: "
                + "\(error.localizedDescription) Add it in Remotes, or delete it on the service."
        case .notPushed(let remote, let page, let error):
            "The repository was made at \(page) and added as “\(remote)”, but the push failed: "
                + "\(error.localizedDescription) Push again once that is fixed."
        }
    }
}
