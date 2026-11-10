import GitKit
import SwiftUI

/// "Push to…" for a local branch's menu.
struct PushToMenuItem: View {
    var model: RepositoryModel
    /// The local branch, by full reference name.
    var branch: String

    var body: some View {
        Button("Push to…", systemImage: "arrow.up.to.line") {
            model.remotes.sheet = .pushTo(branch: branch)
        }
        .disabled(!model.hasRemotes || model.isTransferring)
    }
}

/// A remote branch's actions on the remote, for its menu.
struct RemoteBranchRemoteActions: View {
    var model: RepositoryModel
    /// The remote branch, by full name.
    var branch: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        let name = RepositoryModel.displayName(ofReference: branch)
        let current = model.headBranchName.map { "“\($0)”" } ?? "Current"
        let isBusy = model.isTransferring || (model.snapshot?.state ?? .clean) != .clean
        Divider()
        Button("Pull “\(name)” into \(current)", systemImage: "arrow.down") {
            Task { await model.pull(remoteBranch: branch) }
        }
        .disabled(isBusy || model.headBranchName == nil)
        Button("Rename on Remote…", systemImage: "pencil") {
            model.remotes.sheet = .renameRemoteBranch(branch)
        }
        .disabled(model.isTransferring)
        if let url = model.webURL(forRemoteBranch: branch) {
            Button("Open on Web", systemImage: "safari") { openURL(url) }
        }
        Button("Delete from Remote…", systemImage: "trash", role: .destructive) {
            model.remotes.sheet = .deleteRemoteBranch(branch)
        }
        .disabled(model.isTransferring)
    }
}

/// A tag's actions on remotes, for its menu.
struct TagRemoteActions: View {
    var model: RepositoryModel
    /// The tag, by full reference name.
    var tag: String

    var body: some View {
        let remotes = model.remoteNames
        Divider()
        if remotes.count == 1, let remote = remotes.first {
            Button("Push to “\(remote)”", systemImage: "arrow.up") {
                Task { await model.pushTag(tag, to: remote) }
            }
            .disabled(model.isTransferring)
        } else if !remotes.isEmpty {
            Menu("Push To", systemImage: "arrow.up") {
                ForEach(remotes, id: \.self) { remote in
                    Button(remote) { Task { await model.pushTag(tag, to: remote) } }
                }
            }
            .disabled(model.isTransferring)
        }
        Button("Delete from Remote…", systemImage: "trash", role: .destructive) {
            model.remotes.sheet = .deleteRemoteTag(tag)
        }
        .disabled(remotes.isEmpty || model.isTransferring)
    }
}

/// A remote's menu in the sidebar.
struct RemoteRowActions: View {
    var model: RepositoryModel
    var remote: Remote

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Fetch “\(remote.name)”", systemImage: "arrow.triangle.2.circlepath") {
            Task { await model.fetch(remote: remote.name, prune: true, tags: .automatic) }
        }
        .disabled(model.isTransferring)
        Button("Push All Tags to “\(remote.name)”", systemImage: "tag") {
            Task { await model.pushAllTags(to: remote.name) }
        }
        .disabled(model.isTransferring || model.snapshot?.tags.isEmpty != false)
        if let url = model.webURL(forRemote: remote.name) {
            Button("Open on Web", systemImage: "safari") { openURL(url) }
        }
        Divider()
        Button("Edit…", systemImage: "pencil") {
            model.remotes.sheet = .editRemote(remote)
        }
        Button("Rename…", systemImage: "character.cursor.ibeam") {
            model.remotes.sheet = .renameRemote(remote)
        }
        Button("Remove…", systemImage: "trash", role: .destructive) {
            model.remotes.sheet = .removeRemote(remote)
        }
    }
}
