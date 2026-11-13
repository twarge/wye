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
    /// What the filter field narrows the lists to.
    @State private var filterText = ""
    /// Folders and remotes closed by hand while filtering, when everything
    /// else opens to show its matches. Dropped with the filter, so the
    /// expansion from before comes back.
    @State private var closedWhileFiltering: Set<String> = []
    /// Remotes opened to show their branches.
    @State private var expandedRemotes: Set<String> = []
    /// What a drop onto a branch or the working copy offers.
    @State private var drop: SidebarDropProposal?
    /// When the tags' and remote branches' commits were made, for sorting
    /// by most recent.
    @State private var commitDates: [OID: Date] = [:]

    var body: some View {
        let listing = model.branchListing(staleMonths: staleMonths, autoArchiveMonths: autoArchiveMonths)
        let lists = model.interface.sidebarLists
        List(selection: $model.selection) {
            Section("Workspace", isExpanded: $workspaceExpanded) {
                Label("Working Copy", systemImage: "folder")
                    .badge(model.workingCopy.entries.count)
                    .tag(SidebarItem.workingCopy)
                    // A branch or tag dropped here checks it out, once asked.
                    .dropDestination(for: String.self) { items, _ in
                        propose(items, onto: .workingCopy)
                    }
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)
                Label("Stashes", systemImage: "tray.full")
                    .badge(model.snapshot?.stashes.count ?? 0)
                    .tag(SidebarItem.stashes)
                Label("Reflog", systemImage: "list.bullet.rectangle")
                    .tag(SidebarItem.reflog)
                if let kind = model.pullRequestTarget?.kind {
                    Label(kind.pullRequestTerm + "s", systemImage: "arrow.triangle.pull")
                        .tag(SidebarItem.pullRequests)
                }
            }

            if let snapshot = model.snapshot {
                let pinned = listing.pinned.filter { matches($0.name) }
                let listed = listing.listed.filter { matches($0.name) }
                let branchNodes = BranchFolderNode.tree(of: listed, path: \.name, idPrefix: "local:")
                if !isFiltering || !pinned.isEmpty || !listed.isEmpty {
                    Section(isExpanded: opened($branchesExpanded)) {
                        // Pinned branches first, by their full names, outside the folders.
                        ForEach(pinned) { branch in
                            branchRow(branch, title: branch.name, listing: listing)
                        }
                        BranchFolderRows(
                            nodes: branchNodes,
                            toggled: folders(branchNodes, headBranch: snapshot.head.branchName),
                            headBranch: snapshot.head.branchName
                        ) { branch, name in
                            branchRow(branch, title: name, listing: listing)
                        }
                    } header: {
                        // A commit dropped here starts a branch; a remote
                        // branch is checked out as a local one.
                        Text("Branches")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .dropDestination(for: String.self) { items, _ in
                                propose(items, onto: .branches)
                            }
                    }
                }

                let archived = listing.archived.filter { matches($0.name) }
                if !archived.isEmpty {
                    Section("Archived Branches", isExpanded: opened($archivedExpanded)) {
                        ForEach(archived) { branch in
                            branchRow(branch, title: branch.name, listing: listing)
                        }
                    }
                }

                let remotes = snapshot.remotes.compactMap { remote -> (Remote, [Branch])? in
                    let branches = Self.listedBranches(of: remote).filter { matches($0.name) }
                    return isFiltering && branches.isEmpty ? nil : (remote, branches)
                }
                if !remotes.isEmpty {
                    Section(isExpanded: opened($remotesExpanded)) {
                        ForEach(remotes, id: \.0.id) { remote, branches in
                            let sorted = lists.remoteBranchSort.sorted(
                                branches, name: \.nameWithoutRemote, date: { commitDates[$0.target] }
                            )
                            let shortened = Shortened(
                                sorted, showsAll: isFiltering || lists.remotesShowingAll.contains(remote.name)
                            )
                            let nodes = BranchFolderNode.tree(
                                of: shortened.shown, path: \.nameWithoutRemote, idPrefix: "remote:\(remote.name):"
                            )
                            DisclosureGroup(isExpanded: remoteExpanded(remote.name)) {
                                BranchFolderRows(
                                    nodes: nodes,
                                    toggled: folders(nodes, headBranch: nil),
                                    headBranch: nil
                                ) { branch, name in
                                    Label(name, systemImage: "arrow.triangle.branch")
                                        .tag(SidebarItem.remoteBranch(branch.id))
                                        .draggable(branch.id)
                                }
                                if shortened.hiddenCount > 0 {
                                    ShowAllRow(count: sorted.count) {
                                        var lists = lists
                                        lists.remotesShowingAll.append(remote.name)
                                        model.interface.setSidebarLists(lists)
                                    }
                                }
                            } label: {
                                Label(remote.name, systemImage: "cloud")
                                    .contextMenu { RemoteMenu(model: model, remote: remote) }
                            }
                        }
                    } header: {
                        // Its sort order is in the View menu.
                        Text("Remotes")
                    }
                }

                let tags = snapshot.tags.filter { matches($0.name) }
                if !tags.isEmpty {
                    let sorted = lists.tagSort.sorted(tags, name: \.name, date: { commitDates[$0.target] })
                    let shortened = Shortened(sorted, showsAll: isFiltering || lists.showsAllTags)
                    Section(isExpanded: opened($tagsExpanded)) {
                        ForEach(shortened.shown) { tag in
                            Label(tag.name, systemImage: "tag")
                                .tag(SidebarItem.tag(tag.id))
                                .draggable(tag.id)
                        }
                        if shortened.hiddenCount > 0 {
                            ShowAllRow(count: sorted.count) {
                                var lists = lists
                                lists.showsAllTags = true
                                model.interface.setSidebarLists(lists)
                            }
                        }
                    } header: {
                        // Its sort order is in the View menu. A commit or
                        // branch dropped here is tagged.
                        Text("Tags")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        .dropDestination(for: String.self) { items, _ in
                            propose(items, onto: .tags)
                        }
                    }
                }

                let submodules = snapshot.submodules.filter { matches($0.name) || matches($0.path) }
                if !submodules.isEmpty {
                    Section(isExpanded: opened($submodulesExpanded)) {
                        ForEach(submodules) { submodule in
                            SubmoduleLabel(submodule: submodule)
                                .tag(SidebarItem.submodule(submodule.name))
                        }
                    } header: {
                        // Its actions are in the Repository menu.
                        Text("Submodules")
                    }
                }

                // The main worktree alone is just this repository.
                let worktrees = snapshot.worktrees.filter { matches($0.displayName) || matches($0.path) }
                if model.hasLinkedWorktrees, !worktrees.isEmpty {
                    Section(isExpanded: opened($worktreesExpanded)) {
                        ForEach(worktrees) { worktree in
                            WorktreeLabel(worktree: worktree)
                                .tag(SidebarItem.worktree(worktree.name))
                        }
                    } header: {
                        // Its actions are in the Repository menu.
                        Text("Worktrees")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filterText, placement: .sidebar, prompt: "Filter")
        .onChange(of: isFiltering) {
            closedWhileFiltering = []
        }
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
        .task(id: DatesKey(snapshot: model.snapshot, lists: model.interface.sidebarLists)) {
            await readCommitDates()
        }
        .confirmationDialog(drop?.title ?? "", isPresented: Binding {
            drop != nil
        } set: { if !$0 { drop = nil } }, titleVisibility: .visible, presenting: drop) { proposal in
            ForEach(proposal.choices) { choice in
                Button(choice.title) {
                    Task { await model.performDrop(choice.action) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Rows

    /// A local branch: dragged onto another branch or the working copy, or
    /// a drop target for commits and other branches.
    private func branchRow(_ branch: Branch, title: String, listing: BranchListing) -> some View {
        BranchLabel(branch: branch, title: title, marks: listing.marks[branch.id] ?? .init())
            .tag(SidebarItem.branch(branch.id))
            .draggable(branch.id)
            .dropDestination(for: String.self) { items, _ in
                propose(items, onto: .branch(branch.id))
            }
    }

    /// Asks what to do with a drop, rather than doing anything yet.
    @discardableResult
    private func propose(_ items: [String], onto target: SidebarDropTarget) -> Bool {
        guard let payload = SidebarDragPayload(items), let snapshot = model.snapshot,
              let proposal = SidebarDropProposal.make(payload, onto: target, in: snapshot) else { return false }
        drop = proposal
        Task { await DragCommitTip.dropped.donate() }
        return true
    }

    // MARK: Filtering

    private var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func matches(_ name: String) -> Bool {
        SidebarFilter.matches(name, filterText)
    }

    /// A section opens while filtering, so its matches show, and keeps the
    /// open or closed state it had for when the filter is cleared.
    private func opened(_ isExpanded: Binding<Bool>) -> Binding<Bool> {
        Binding {
            isFiltering || isExpanded.wrappedValue
        } set: { expanded in
            if !isFiltering { isExpanded.wrappedValue = expanded }
        }
    }

    /// The folders toggled against their default. While filtering, all of
    /// them open, except any closed by hand meanwhile.
    private func folders(_ nodes: [BranchFolderNode], headBranch: String?) -> Binding<Set<String>> {
        guard isFiltering else { return $toggledFolders }
        let closed = SidebarFilter.closedFolders(in: nodes, headBranch: headBranch)
        // A folder is toggled against its default exactly when it is closed
        // by default and not closed by hand, or the other way round; the
        // same rule read backwards keeps what was closed by hand.
        return Binding {
            closed.symmetricDifference(closedWhileFiltering)
        } set: { toggled in
            closedWhileFiltering = closed.symmetricDifference(toggled)
        }
    }

    private func remoteExpanded(_ name: String) -> Binding<Bool> {
        Binding {
            isFiltering ? !closedWhileFiltering.contains("remote:" + name) : expandedRemotes.contains(name)
        } set: { expanded in
            if isFiltering {
                if expanded { closedWhileFiltering.remove("remote:" + name) } else { closedWhileFiltering.insert("remote:" + name) }
            } else if expanded {
                expandedRemotes.insert(name)
            } else {
                expandedRemotes.remove(name)
            }
        }
    }

    // MARK: Sorting

    private struct DatesKey: Hashable {
        var snapshot: RepositorySnapshot?
        var lists: SidebarListOptions
    }

    /// Reads the commit dates that sorting by most recent needs, and only then.
    private func readCommitDates() async {
        guard let snapshot = model.snapshot else { return }
        let lists = model.interface.sidebarLists
        var ids: Set<OID> = []
        if lists.tagSort == .recent { ids.formUnion(snapshot.tags.map(\.target)) }
        if lists.remoteBranchSort == .recent { ids.formUnion(snapshot.remotes.flatMap(\.branches).map(\.target)) }
        ids.subtract(commitDates.keys)
        guard !ids.isEmpty else { return }
        let dates = await model.repository.commitDates(of: ids)
        commitDates.merge(dates) { _, new in new }
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
        case .history, .stashes, .reflog, .pullRequests:
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
                // The checked-out branch is bold, as its commit is in the history.
                Text(title)
                    .fontWeight(branch.isHead ? .bold : nil)
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
            }
            .font(.body.monospacedDigit())
        } icon: {
            Image(systemName: "arrow.triangle.branch")
        }
        .help(branch.isHead ? "\(branch.name) (checked out)" : branch.name)
        .accessibilityValue(branch.isHead ? "Checked out" : "")
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
