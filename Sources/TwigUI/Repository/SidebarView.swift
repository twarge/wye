import GitKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: RepositoryModel
    /// Branch folders opened or closed against their default.
    @State private var toggledFolders: Set<String> = []
    // Which sections are open, remembered between launches. Each heading
    // gets the list's own disclosure control at its trailing edge.
    @AppStorage("sidebar.workspaceExpanded") private var workspaceExpanded = true
    @AppStorage("sidebar.branchesExpanded") private var branchesExpanded = true
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = true
    @AppStorage("sidebar.remotesExpanded") private var remotesExpanded = true
    @AppStorage("sidebar.submodulesExpanded") private var submodulesExpanded = true
    @AppStorage("sidebar.worktreesExpanded") private var worktreesExpanded = true
    @AppStorage("sidebar.archivedExpanded") private var archivedExpanded = false
    @AppStorage(BranchPreferences.staleMonthsKey) private var staleMonths = 3
    @AppStorage(BranchPreferences.autoArchiveMonthsKey) private var autoArchiveMonths = 0

    var body: some View {
        let listing = model.branchListing(staleMonths: staleMonths, autoArchiveMonths: autoArchiveMonths)
        List(selection: $model.selection) {
            Section("Workspace", isExpanded: $workspaceExpanded) {
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
                Section("Branches", isExpanded: $branchesExpanded) {
                    // Pinned branches first, by their full names, outside the folders.
                    ForEach(listing.pinned) { branch in
                        BranchLabel(branch: branch, title: branch.name, marks: listing.marks[branch.id] ?? .init())
                            .tag(SidebarItem.branch(branch.id))
                    }
                    BranchFolderRows(
                        nodes: BranchFolderNode.tree(of: listing.listed, path: \.name, idPrefix: "local:"),
                        toggled: $toggledFolders,
                        headBranch: snapshot.head.branchName
                    ) { branch, name in
                        BranchLabel(branch: branch, title: name, marks: listing.marks[branch.id] ?? .init())
                            .tag(SidebarItem.branch(branch.id))
                    }
                }

                if !listing.archived.isEmpty {
                    Section("Archived Branches", isExpanded: $archivedExpanded) {
                        ForEach(listing.archived) { branch in
                            BranchLabel(branch: branch, title: branch.name, marks: listing.marks[branch.id] ?? .init())
                                .tag(SidebarItem.branch(branch.id))
                        }
                    }
                }

                if !snapshot.remotes.isEmpty {
                    Section("Remotes", isExpanded: $remotesExpanded) {
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
                                    .contextMenu { RemoteMenu(model: model, remote: remote) }
                            }
                        }
                    }
                }

                if !snapshot.tags.isEmpty {
                    Section("Tags", isExpanded: $tagsExpanded) {
                        ForEach(snapshot.tags) { tag in
                            Label(tag.name, systemImage: "tag")
                                .tag(SidebarItem.tag(tag.id))
                        }
                    }
                }

                if !snapshot.submodules.isEmpty {
                    Section(isExpanded: $submodulesExpanded) {
                        ForEach(snapshot.submodules) { submodule in
                            SubmoduleLabel(submodule: submodule)
                                .tag(SidebarItem.submodule(submodule.name))
                        }
                    } header: {
                        SidebarSectionHeader(title: "Submodules") { AllSubmodulesActions(model: model) }
                    }
                }

                // The main worktree alone is just this repository.
                if model.hasLinkedWorktrees {
                    Section(isExpanded: $worktreesExpanded) {
                        ForEach(snapshot.worktrees) { worktree in
                            WorktreeLabel(worktree: worktree)
                                .tag(SidebarItem.worktree(worktree.name))
                        }
                    } header: {
                        SidebarSectionHeader(title: "Worktrees") { AllWorktreesActions(model: model) }
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
                menu(for: item, listing: listing)
            }
        }, primaryAction: doubleClickAction)
        .task(id: model.snapshot) {
            // Merged and stale marks, worked out off the main thread.
            await model.updateBranchReview()
        }
    }

    /// `origin/HEAD` only says which branch the remote has checked out; it
    /// is not one more.
    private static func listedBranches(of remote: Remote) -> [Branch] {
        remote.branches.filter { $0.nameWithoutRemote != "HEAD" }
    }

    // MARK: Menus

    /// Each row's menu, from its own file under Menus.
    @ViewBuilder
    private func menu(for item: SidebarItem, listing: BranchListing) -> some View {
        switch item {
        case .workingCopy:
            WorkingCopyRowMenu(model: model)
        case .branch(let id):
            if let branch = model.snapshot?.branches.first(where: { $0.id == id }) {
                BranchMenu(
                    model: model, branch: branch, marks: listing.marks[id] ?? .init(),
                    isArchived: listing.archived.contains { $0.id == id }
                )
            }
        case .remoteBranch(let id):
            if let branch = model.snapshot?.remotes.flatMap(\.branches).first(where: { $0.id == id }) {
                RemoteBranchMenu(model: model, branch: branch)
            }
        case .tag(let id):
            if let tag = model.snapshot?.tags.first(where: { $0.id == id }) {
                TagMenu(model: model, tag: tag)
            }
        case .submodule(let name):
            if let submodule = model.submodule(named: name) {
                SubmoduleActions(model: model, submodule: submodule)
            }
        case .worktree(let name):
            if let worktree = model.worktree(named: name) {
                WorktreeActions(model: model, worktree: worktree)
            }
        case .history, .stashes, .reflog:
            EmptyView()
        }
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
            case .submodule(let name):
                model.nested.opening = .submodule(name)
            case .worktree(let name):
                model.nested.opening = .worktree(name)
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
    var marks: BranchListing.Marks

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if marks.isPinned {
                    mark("pin.fill", "Pinned")
                }
                if marks.isMerged {
                    mark("checkmark.circle", "Merged", help: "Everything on this branch is in the main branch")
                }
                if marks.isStale {
                    mark("clock", "Stale", help: "No commits for a while")
                }
                if let upstream = branch.upstream {
                    if upstream.ahead > 0 {
                        Text("↑\(upstream.ahead)")
                    }
                    if upstream.behind > 0 {
                        Text("↓\(upstream.behind)")
                    }
                }
                if let path = branch.worktreePath {
                    Image(systemName: "square.on.square")
                        .foregroundStyle(.secondary)
                        .help("Checked out in the worktree at \(path)")
                        .accessibilityLabel("Checked out in another worktree")
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

    /// A small mark beside the name, said aloud as `label`.
    private func mark(_ systemImage: String, _ label: String, help: String? = nil) -> some View {
        Image(systemName: systemImage)
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .help(help ?? label)
            .accessibilityLabel(label)
    }
}
