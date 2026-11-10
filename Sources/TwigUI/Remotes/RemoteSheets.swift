import GitKit
import SwiftUI

extension View {
    /// Shows the remote sheets that menus ask for.
    func remoteSheets(_ model: RepositoryModel) -> some View {
        modifier(RemoteSheets(model: model))
    }
}

private struct RemoteSheets: ViewModifier {
    @Bindable var model: RepositoryModel

    func body(content: Content) -> some View {
        @Bindable var remotes = model.remotes
        content.sheet(item: $remotes.sheet) { sheet in
            switch sheet {
            case .pullOptions:
                PullOptionsSheet(model: model)
            case .fetchOptions:
                FetchOptionsSheet(model: model)
            case .pushTo(let branch):
                PushToSheet(model: model, branch: branch)
            case .editRemote(let remote):
                RemoteEditor(model: model, subject: .existing(remote))
            case .renameRemote(let remote):
                RenameRemoteSheet(model: model, remote: remote)
            case .removeRemote(let remote):
                RemoveRemoteSheet(model: model, remote: remote)
            case .deleteRemoteBranch(let branch):
                DeleteRemoteBranchSheet(model: model, branch: branch)
            case .renameRemoteBranch(let branch):
                RenameRemoteBranchSheet(model: model, branch: branch)
            case .deleteRemoteTag(let tag):
                DeleteRemoteTagSheet(model: model, tag: tag)
            }
        }
    }
}

// MARK: Pull and fetch

/// Pull with a chosen mode, from the upstream or another remote branch,
/// stashing local changes or not.
struct PullOptionsSheet: View {
    var model: RepositoryModel

    @State private var mode = RemotePreferences.pullMode
    /// A remote branch by full name; empty for the upstream.
    @State private var source = ""
    @State private var autostash = RemotePreferences.autostash == .always

    var body: some View {
        BranchingSheetForm(title: "Pull", confirmTitle: "Pull", canConfirm: canPull, confirm: pull) {
            Section {
                Picker("From", selection: $source) {
                    Text(upstreamTitle).tag("")
                    ForEach(remoteBranches) { branch in
                        Text(branch.name).tag(branch.id)
                    }
                }
                LabeledContent("Into", value: model.headBranchName ?? "Detached HEAD")
            }
            Section {
                Picker("Pull By", selection: $mode) {
                    ForEach(PullMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(mode.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Stash Local Changes First", isOn: $autostash)
            } footer: {
                Text("Sets changes to tracked files aside before pulling and puts them back afterwards. "
                     + "Without it, changes in the way stop the pull.")
            }
        }
        .task {
            mode = await model.defaultPullMode()
        }
    }

    private var remoteBranches: [Branch] {
        (model.snapshot?.remotes.flatMap(\.branches) ?? []).filter { $0.nameWithoutRemote != "HEAD" }
    }

    private var upstreamTitle: String {
        model.currentBranch?.upstream.map { "Upstream (\($0.name))" } ?? "Upstream (none)"
    }

    private var canPull: Bool {
        model.headBranchName != nil && (!source.isEmpty || model.currentBranch?.upstream != nil)
    }

    private func pull() {
        let (mode, source, autostash) = (mode, source, autostash)
        Task {
            if source.isEmpty {
                await model.pull(mode: mode, autostash: autostash)
            } else {
                await model.pull(remoteBranch: source, mode: mode, autostash: autostash)
            }
        }
    }
}

/// Fetch one remote or all, choosing whether to prune and which tags come.
struct FetchOptionsSheet: View {
    var model: RepositoryModel

    /// A remote's name; empty for every remote.
    @State private var remote = ""
    @State private var prune = true
    @State private var tags = FetchTags.automatic

    var body: some View {
        BranchingSheetForm(title: "Fetch", confirmTitle: "Fetch", canConfirm: model.hasRemotes, confirm: fetch) {
            Section {
                Picker("From", selection: $remote) {
                    Text("All Remotes").tag("")
                    ForEach(model.remoteNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
            Section {
                Toggle("Remove Deleted Remote Branches", isOn: $prune)
                Picker("Tags", selection: $tags) {
                    ForEach(FetchTags.allCases, id: \.self) { tags in
                        Text(tags.title).tag(tags)
                    }
                }
            } footer: {
                Text(tags.explanation)
            }
        }
    }

    private func fetch() {
        let (remote, prune, tags) = (remote, prune, tags)
        Task { await model.fetch(remote: remote.isEmpty ? nil : remote, prune: prune, tags: tags) }
    }
}

extension FetchTags {
    var title: String {
        switch self {
        case .automatic: "As Usual"
        case .all: "All Tags"
        case .none: "No Tags"
        }
    }

    var explanation: String {
        switch self {
        case .automatic: "Tags come as the remote’s configuration says: usually the remote’s tags."
        case .all: "Every tag on the remote comes, wherever it points."
        case .none: "No tags are fetched."
        }
    }
}

// MARK: Push to

/// Pushes any local branch to a chosen remote and branch name.
struct PushToSheet: View {
    var model: RepositoryModel

    @State private var branch: String
    @State private var remote = ""
    @State private var remoteBranch = ""
    @State private var setUpstream = false

    init(model: RepositoryModel, branch: String?) {
        self.model = model
        let branch = branch ?? model.snapshot?.head.branchName ?? model.snapshot?.branches.first?.id ?? ""
        _branch = State(initialValue: branch)
        _remoteBranch = State(initialValue: RepositoryModel.displayName(ofReference: branch))
        _remote = State(initialValue: model.defaultRemoteName ?? model.remoteNames.first ?? "")
        _setUpstream = State(initialValue: model.snapshot?.branches.first { $0.id == branch }?.upstream == nil)
    }

    var body: some View {
        BranchingSheetForm(title: "Push To", confirmTitle: "Push", canConfirm: canPush, confirm: push) {
            Section {
                Picker("Branch", selection: $branch) {
                    ForEach(model.snapshot?.branches ?? []) { branch in
                        Text(branch.name).tag(branch.id)
                    }
                }
                .onChange(of: branch) { _, branch in
                    remoteBranch = RepositoryModel.displayName(ofReference: branch)
                    setUpstream = model.snapshot?.branches.first { $0.id == branch }?.upstream == nil
                }
            }
            Section {
                Picker("Remote", selection: $remote) {
                    ForEach(model.remoteNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                TextField("Remote Branch", text: $remoteBranch)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                Toggle("Track the Remote Branch", isOn: $setUpstream)
            } footer: {
                Text("Pushes “\(RepositoryModel.displayName(ofReference: branch))” to \(destination). "
                     + "A push that would drop commits on the remote is refused.")
            }
        }
    }

    private var trimmedName: String { remoteBranch.trimmingCharacters(in: .whitespaces) }

    private var destination: String {
        remote.isEmpty || trimmedName.isEmpty ? "the remote" : "“\(remote)/\(trimmedName)”"
    }

    private var canPush: Bool {
        !branch.isEmpty && !remote.isEmpty && !trimmedName.isEmpty
    }

    private func push() {
        let (branch, remote, name, setUpstream) = (branch, remote, trimmedName, setUpstream)
        Task { await model.push(branch: branch, to: remote, as: name, setUpstream: setUpstream) }
    }
}

// MARK: Remotes

struct RenameRemoteSheet: View {
    var model: RepositoryModel
    var remote: Remote

    @State private var name: String

    init(model: RepositoryModel, remote: Remote) {
        self.model = model
        self.remote = remote
        _name = State(initialValue: remote.name)
    }

    var body: some View {
        BranchingSheetForm(title: "Rename Remote", confirmTitle: "Rename", canConfirm: canRename, confirm: rename) {
            Section {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
            } footer: {
                Text("Its remote branches, and the local branches that follow them, move to the new name.")
            }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var canRename: Bool { !trimmed.isEmpty && trimmed != remote.name }

    private func rename() {
        let (remote, name) = (remote, trimmed)
        Task { await model.editRemote(remote, name: name, url: remote.url ?? "") }
    }
}

struct RemoveRemoteSheet: View {
    var model: RepositoryModel
    var remote: Remote

    var body: some View {
        BranchingSheetForm(title: "Remove Remote", confirmTitle: "Remove", isDestructive: true, confirm: remove) {
            Section {
                LabeledContent("Remote", value: remote.name)
                LabeledContent("URL", value: remote.url ?? "None")
            } footer: {
                Text(Self.consequences(of: remote))
            }
        }
    }

    static func consequences(of remote: Remote) -> String {
        let count = remote.branches.count
        return "Its \(count) remote \(count == 1 ? "branch goes" : "branches go") too. "
            + "Nothing on the remote itself is changed, and local branches are kept."
    }

    private func remove() {
        let remote = remote
        Task { await model.removeRemote(remote) }
    }
}

// MARK: Branches and tags on a remote

/// Confirms deleting a branch on its remote, which affects everyone using it.
struct DeleteRemoteBranchSheet: View {
    var model: RepositoryModel
    /// The remote branch, by full name.
    var branch: String

    var body: some View {
        BranchingSheetForm(
            title: "Delete Remote Branch", confirmTitle: "Delete", isDestructive: true,
            canConfirm: !model.isTransferring, confirm: delete
        ) {
            Section {
                LabeledContent("Branch", value: parts.branch)
                LabeledContent("On", value: parts.remote)
            } footer: {
                Text("Deletes “\(parts.branch)” on “\(parts.remote)” for everyone who uses it. Commits that "
                     + "only it holds there are lost unless someone still has them. "
                     + "Local branches here are kept.")
            }
        }
    }

    private var parts: (remote: String, branch: String) { model.remoteParts(of: branch) }

    private func delete() {
        let branch = branch
        Task { await model.deleteRemoteBranch(branch) }
    }
}

/// Renames a branch on its remote: pushes the new name, deletes the old.
struct RenameRemoteBranchSheet: View {
    var model: RepositoryModel
    var branch: String

    @State private var name: String

    init(model: RepositoryModel, branch: String) {
        self.model = model
        self.branch = branch
        _name = State(initialValue: model.remoteParts(of: branch).branch)
    }

    var body: some View {
        BranchingSheetForm(
            title: "Rename Remote Branch", confirmTitle: "Rename", isDestructive: true,
            canConfirm: canRename, confirm: rename
        ) {
            Section {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
            } footer: {
                Text("Pushes the branch to “\(parts.remote)” under the new name, then deletes "
                     + "“\(parts.branch)” there. Anyone else using the old name has to switch to the new one. "
                     + "Local branches that follow it here are switched for you.")
            }
        }
    }

    private var parts: (remote: String, branch: String) { model.remoteParts(of: branch) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var canRename: Bool {
        !trimmed.isEmpty && trimmed != parts.branch && !model.isTransferring
    }

    private func rename() {
        let (branch, name) = (branch, trimmed)
        Task { await model.renameRemoteBranch(branch, to: name) }
    }
}

/// Confirms deleting a tag on a chosen remote.
struct DeleteRemoteTagSheet: View {
    var model: RepositoryModel
    var tag: String

    @State private var remote: String

    init(model: RepositoryModel, tag: String) {
        self.model = model
        self.tag = tag
        _remote = State(initialValue: model.defaultRemoteName ?? model.remoteNames.first ?? "")
    }

    var body: some View {
        BranchingSheetForm(
            title: "Delete Tag on Remote", confirmTitle: "Delete", isDestructive: true,
            canConfirm: !remote.isEmpty && !model.isTransferring, confirm: delete
        ) {
            Section {
                LabeledContent("Tag", value: RepositoryModel.displayName(ofReference: tag))
                Picker("Remote", selection: $remote) {
                    ForEach(model.remoteNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            } footer: {
                Text("Deletes the tag on “\(remote)” for everyone who uses it. The tag here is kept, "
                     + "and so are its commits.")
            }
        }
    }

    private func delete() {
        let (tag, remote) = (tag, remote)
        Task { await model.deleteRemoteTag(tag, on: remote) }
    }
}

extension RepositoryModel {
    /// A remote branch's remote and its name there: `origin` and `topic`
    /// for `refs/remotes/origin/topic`. The longest remote name that fits
    /// wins, since remote names can hold slashes.
    func remoteParts(of remoteBranch: String) -> (remote: String, branch: String) {
        let name = Self.displayName(ofReference: remoteBranch)
        let remote = remoteNames.filter { name.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            ?? name.split(separator: "/").first.map(String.init) ?? name
        return (remote, String(name.dropFirst(min(name.count, remote.count + 1))))
    }
}
