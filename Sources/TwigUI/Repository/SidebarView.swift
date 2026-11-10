import GitKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: RepositoryModel
    /// Branch folders opened or closed against their default.
    @State private var toggledFolders: Set<String> = []

    var body: some View {
        List(selection: $model.selection) {
            Section("Workspace") {
                Label("Working Copy", systemImage: "folder")
                    .badge(model.workingCopy.entries.count)
                    .tag(SidebarItem.workingCopy)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)
                Label("Stashes", systemImage: "tray.full")
                    .badge(model.snapshot?.stashes.count ?? 0)
                    .tag(SidebarItem.stashes)
                Label("Reflog", systemImage: "list.bullet.rectangle")
                    .tag(SidebarItem.reflog)
            }

            if let snapshot = model.snapshot {
                Section("Branches") {
                    BranchFolderRows(
                        nodes: BranchFolderNode.tree(of: snapshot.branches, path: \.name, idPrefix: "local:"),
                        toggled: $toggledFolders,
                        headBranch: snapshot.head.branchName
                    ) { branch, name in
                        BranchLabel(branch: branch, title: name)
                            .tag(SidebarItem.branch(branch.id))
                    }
                }

                if !snapshot.tags.isEmpty {
                    Section("Tags") {
                        ForEach(snapshot.tags) { tag in
                            Label(tag.name, systemImage: "tag")
                                .tag(SidebarItem.tag(tag.id))
                        }
                    }
                }

                if !snapshot.remotes.isEmpty {
                    Section("Remotes") {
                        ForEach(snapshot.remotes) { remote in
                            DisclosureGroup {
                                BranchFolderRows(
                                    nodes: BranchFolderNode.tree(
                                        of: Self.listedBranches(of: remote), path: \.nameWithoutRemote,
                                        idPrefix: "remote:\(remote.name):"
                                    ),
                                    toggled: $toggledFolders,
                                    headBranch: nil
                                ) { branch, name in
                                    Label(name, systemImage: "arrow.triangle.branch")
                                        .tag(SidebarItem.remoteBranch(branch.id))
                                }
                            } label: {
                                Label(remote.name, systemImage: "cloud")
                                    .contextMenu { RemoteRowActions(model: model, remote: remote) }
                            }
                        }
                    }
                }

                if !snapshot.submodules.isEmpty {
                    Section("Submodules") {
                        ForEach(snapshot.submodules) { submodule in
                            Label(submodule.path, systemImage: "shippingbox")
                                .tag(SidebarItem.submodule(submodule.name))
                        }
                    }
                }

                if !snapshot.worktrees.isEmpty {
                    Section("Worktrees") {
                        ForEach(snapshot.worktrees) { worktree in
                            Label(worktree.name, systemImage: "square.on.square")
                                .tag(SidebarItem.worktree(worktree.name))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(model.name)
        .safeAreaInset(edge: .bottom) {
            OperationBanner(model: model)
                .padding(8)
        }
        .contextMenu(forSelectionType: SidebarItem.self, menu: { items in
            if items.count == 1, let item = items.first {
                menu(for: item)
            }
        }, primaryAction: doubleClickAction)
    }

    /// `origin/HEAD` only says which branch the remote has checked out; it
    /// is not one more.
    private static func listedBranches(of remote: Remote) -> [Branch] {
        remote.branches.filter { $0.nameWithoutRemote != "HEAD" }
    }

    // MARK: Menus

    @ViewBuilder
    private func menu(for item: SidebarItem) -> some View {
        switch item {
        case .branch(let id):
            branchMenu(id)
        case .remoteBranch(let id):
            remoteBranchMenu(id)
        case .tag(let id):
            Button("Check Out", systemImage: "arrow.uturn.down") {
                Task { await model.checkOutTag(id) }
            }
            .disabled(isBusy)
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) {
                model.present(.deleteTag(id))
            }
            TagRemoteActions(model: model, tag: id)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func branchMenu(_ id: String) -> some View {
        let isHead = model.snapshot?.head.branchName == id
        let name = RepositoryModel.displayName(ofReference: id)
        let current = model.headBranchName.map { "“\($0)”" } ?? "Current"

        Button("Check Out", systemImage: "arrow.uturn.down") {
            Task { await model.checkOutBranch(id) }
        }
        .disabled(isHead || isBusy)

        Divider()

        Button("Merge “\(name)” into \(current)…", systemImage: "arrow.triangle.merge") {
            model.present(.merge(id))
        }
        .disabled(isHead || isBusy)
        Button("Rebase \(current) onto “\(name)”…", systemImage: "arrow.triangle.pull") {
            model.present(.rebase(onto: id))
        }
        .disabled(isHead || isBusy || model.headBranchName == nil)

        Divider()

        Button("Rename…", systemImage: "pencil") {
            model.present(.renameBranch(id))
        }
        upstreamMenu(for: id)
        PushToMenuItem(model: model, branch: id)
        Button("Delete…", systemImage: "trash", role: .destructive) {
            model.present(.deleteBranch(id))
        }
        .disabled(isHead)
    }

    @ViewBuilder
    private func remoteBranchMenu(_ id: String) -> some View {
        let name = RepositoryModel.displayName(ofReference: id)
        let current = model.headBranchName.map { "“\($0)”" } ?? "Current"

        Button("Check Out as Local Branch", systemImage: "arrow.uturn.down") {
            Task { await model.trackRemoteBranch(id) }
        }
        .disabled(isBusy)

        Divider()

        Button("Merge “\(name)” into \(current)…", systemImage: "arrow.triangle.merge") {
            model.present(.merge(id))
        }
        .disabled(isBusy)
        Button("Rebase \(current) onto “\(name)”…", systemImage: "arrow.triangle.pull") {
            model.present(.rebase(onto: id))
        }
        .disabled(isBusy || model.headBranchName == nil)
        RemoteBranchRemoteActions(model: model, branch: id)
    }

    /// Which remote branch a local branch follows.
    private func upstreamMenu(for id: String) -> some View {
        let upstream = model.snapshot?.branches.first { $0.id == id }?.upstream?.name
        let candidates = model.snapshot?.remotes.flatMap(Self.listedBranches) ?? []
        return Menu("Set Upstream", systemImage: "arrow.up.arrow.down") {
            ForEach(candidates) { candidate in
                Button {
                    Task { await model.setUpstream(of: id, to: candidate.id) }
                } label: {
                    if candidate.name == upstream {
                        Label(candidate.name, systemImage: "checkmark")
                    } else {
                        Text(candidate.name)
                    }
                }
            }
            if !candidates.isEmpty {
                Divider()
            }
            Button("None") {
                Task { await model.setUpstream(of: id, to: nil) }
            }
            .disabled(upstream == nil)
        }
    }

    /// Whether a merge, rebase or the like has to be finished first.
    private var isBusy: Bool {
        model.snapshot?.state ?? .clean != .clean
    }

    /// Double-clicking a branch checks it out, and a remote branch checks
    /// it out as a local one, where there is a double-click. On iOS a tap
    /// selects instead.
    private var doubleClickAction: ((Set<SidebarItem>) -> Void)? {
        guard Platform.hasDoubleClick else { return nil }
        return { items in
            guard items.count == 1 else { return }
            switch items.first {
            case .branch(let id) where model.snapshot?.head.branchName != id:
                Task { await model.checkOutBranch(id) }
            case .remoteBranch(let id):
                Task { await model.trackRemoteBranch(id) }
            default:
                break
            }
        }
    }
}

private struct BranchLabel: View {
    var branch: Branch
    /// The name within its folder.
    var title: String

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let upstream = branch.upstream {
                    if upstream.ahead > 0 {
                        Text("↑\(upstream.ahead)")
                    }
                    if upstream.behind > 0 {
                        Text("↓\(upstream.behind)")
                    }
                }
                if branch.isHead {
                    Text("HEAD")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(.quaternary, in: .capsule)
                }
            }
            .font(.body.monospacedDigit())
        } icon: {
            Image(systemName: "arrow.triangle.branch")
        }
        .help(branch.name)
    }
}
