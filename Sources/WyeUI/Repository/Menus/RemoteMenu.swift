import GitKit
import SwiftUI

/// The menu of a remote in the sidebar, top to bottom: fetch, prune, push
/// tags, edit, rename or remove it, open it on the web.
struct RemoteMenu: View {
    var model: RepositoryModel
    var remote: Remote

    @Environment(\.openURL) private var openURL

    var body: some View {
        let isTransferring = model.isTransferring
        Section {
            Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
                Task { await model.fetch(remote: remote.name, prune: FetchPreferences.prune, tags: .automatic) }
            }
            .disabled(isTransferring)
            .help("Fetch new commits, and remove remote branches that are gone from the remote")
        }
        Section {
            Button("Prune Remote Branches", systemImage: "scissors") {
                Task { await model.pruneRemote(remote.name) }
            }
            .disabled(isTransferring)
            .help("Remove the remote branches that are gone from the remote, without fetching anything")
        }
        Section {
            Button("Push All Tags", systemImage: "tag") {
                Task { await model.pushAllTags(to: remote.name) }
            }
            .disabled(isTransferring || model.snapshot?.tags.isEmpty != false)
        }
        Section {
            Button("Edit…", systemImage: "slider.horizontal.3") {
                model.remotes.sheet = .editRemote(remote)
            }
            .help("Change its name, URL and push URL")
            if model.hostedRepository(remote: remote.name) != nil {
                Button("Account…", systemImage: "person.crop.circle") {
                    model.hosting.sheet = .account(remote: remote.name)
                }
                .help("Choose the account this remote signs in with")
            }
        }
        Section {
            Button("Rename…", systemImage: "character.cursor.ibeam") {
                model.remotes.sheet = .renameRemote(remote)
            }
            Button("Remove…", systemImage: "trash", role: .destructive) {
                model.remotes.sheet = .removeRemote(remote)
            }
        }
        if let url = model.webURL(forRemote: remote.name) {
            Section {
                Button("Open on Web", systemImage: "safari") { openURL(url) }
            }
        }
    }
}

/// The menu of a remote branch in the sidebar, top to bottom: check it out
/// or pull it, bring it into the current branch, start a branch or pull
/// request from it, rename or delete it on the remote, and the items every
/// reference has.
struct RemoteBranchMenu: View {
    var model: RepositoryModel
    /// The remote branch, by full name.
    var branch: Branch

    @Environment(\.openURL) private var openURL

    var body: some View {
        let id = branch.id
        let current = MenuNames.current(model)
        let isTransferring = model.isTransferring

        Section {
            Button("Check Out as Local Branch", systemImage: "arrow.uturn.down") {
                Task { await model.trackRemoteBranch(id) }
            }
            .disabled(model.isBusy)
            .help("Check out a local branch of the same name that tracks it, making one if there is none")
            Button("Pull into \(current)", systemImage: "arrow.down") {
                Task { await model.pull(remoteBranch: id) }
            }
            .disabled(isTransferring || model.isBusy || model.headBranchName == nil)
        }

        Section {
            Button("Merge into \(current)…", systemImage: "arrow.triangle.merge") {
                model.present(.merge(id))
            }
            .disabled(model.isBusy)
            Button("Rebase \(current) onto Here…", systemImage: "arrow.triangle.pull") {
                model.present(.rebase(onto: id))
            }
            .disabled(model.isBusy || model.headBranchName == nil)
        }

        Section {
            Button("New Tracking Branch…", systemImage: "arrow.triangle.branch") {
                model.present(.trackRemoteBranch(id))
            }
            .help("Make a local branch that tracks it, with a name you choose")
            Button("New Branch from Here…", systemImage: "plus") {
                model.present(.newBranch(at: branch.target))
            }
            let url = model.pullRequestURL(forRemoteBranch: id)
            PullRequestButton(
                title: "New Pull Request from Here…", url: url,
                unavailable: url == nil ? RepositoryModel.unknownHostReason : nil
            )
        }

        Section {
            Button("Rename on Remote…", systemImage: "pencil") {
                model.remotes.sheet = .renameRemoteBranch(id)
            }
            .disabled(isTransferring)
            Button("Delete from Remote…", systemImage: "trash", role: .destructive) {
                model.remotes.sheet = .deleteRemoteBranch(id)
            }
            .disabled(isTransferring)
        }

        ReferenceFooterItems(model: model, name: branch.name, target: branch.target, copyTitle: "Copy Remote Branch Name")

        if let url = model.webURL(forRemoteBranch: id) {
            Section {
                Button("Open on Web", systemImage: "safari") { openURL(url) }
            }
        }
    }
}
