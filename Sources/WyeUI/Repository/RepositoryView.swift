import GitKit
import SwiftUI

/// A repository window: sidebar, a list for what the sidebar selects, and the
/// detail of what that list selects.
struct RepositoryView: View {
    @Bindable var model: RepositoryModel
    var close: () -> Void

    @Environment(WindowActions.self) private var actions: WindowActions?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Whether the detail is open on the right, on macOS.
    @SceneStorage("showsDetail") private var showsDetail = true

    var body: some View {
        columns
            .focusedSceneValue(model)
            .opensCommitWindows(model)
            // For diffs that read more than their lines, such as images.
            .environment(\.diffRepository, model.repository)
            .repositoryWindowServices(model)
            .modifier(notices(perColumn: false))
            .branchingSheets(model)
            .remoteDialogs(for: model)
            .fileRequestDialogs(model)
            .nestedDialogs(model)
            .hostingDialogs(model)
            .commitNotePresenters(model)
            .rebasePresenters(model)
            .background {
                // The sidebar's menus ask for them too, so they do not wait
                // for the history to be on screen; on a view of their own,
                // whose file dialogs then take no others' place.
                Color.clear.commitActionPresenters(model)
            }
            .task {
                await model.refresh()
            }
            .task {
                // Until the window closes or shows another repository.
                await model.watchForChanges()
            }
            .task(id: HistoryKey(selection: model.selection, referenceCommit: model.commitToReveal)) {
                // One after the other, so the reveal reads the history shown.
                if let scope = model.selection?.historyScope {
                    await model.history.show(scope)
                }
                await model.revealSelectedReference()
            }
    }

    /// The sidebar, the list, and the detail of what it selects. On macOS
    /// the detail is an inspector, which the toolbar's button and
    /// View ▸ Hide Inspector close: a split view's last column cannot be.
    @ViewBuilder
    private var columns: some View {
        #if os(macOS)
        NavigationSplitView {
            sidebar
        } detail: {
            list
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showsDetail.toggle()
                        } label: {
                            Label(showsDetail ? "Hide Details" : "Show Details", systemImage: "sidebar.right")
                        }
                        .help(showsDetail ? "Hide the details on the right" : "Show the details on the right")
                    }
                }
                .inspector(isPresented: $showsDetail) {
                    detailColumn
                        .inspectorColumnWidth(min: 320, ideal: 560, max: 1600)
                }
        }
        #else
        NavigationSplitView {
            sidebar
        } content: {
            list
                .navigationSplitViewColumnWidth(min: 320, ideal: 500)
        } detail: {
            detailColumn
        }
        #endif
    }

    private var sidebar: some View {
        SidebarView(model: model)
            .modifier(notices(perColumn: true))
            // Opens at its narrowest.
            .navigationSplitViewColumnWidth(min: 150, ideal: 150, max: 380)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Repositories", systemImage: "square.grid.2x2", action: close)
                        .help("Show all repositories")
                }
            }
    }

    private var list: some View {
        content
            .modifier(notices(perColumn: true))
            // The window stands for the repository's folder: on macOS the
            // title gets the folder's icon, to drag, and a menu of the
            // folders that enclose it.
            .navigationDocument(model.repository.url)
            // On the list's column, so it shows whatever the sidebar selects.
            .remoteControls(for: model)
            .undoControls(for: model)
    }

    private var detailColumn: some View {
        detail
            .modifier(notices(perColumn: true))
    }

    /// What the history on screen depends on: the sidebar's selection and,
    /// for a branch or tag, the commit it points at, which one selected
    /// inside an operation gets only once the refresh after it lists it.
    private struct HistoryKey: Hashable {
        var selection: SidebarItem?
        var referenceCommit: OID?
    }

    /// The strip of notices, over the whole window where the columns sit
    /// side by side. On an iPhone one column fills the screen under its
    /// own bar, so each carries the strip below that bar: over the window
    /// it would cover the bar's buttons.
    ///
    /// The window's own notices show too: adding or opening another
    /// repository can fail while this one is on screen.
    private func notices(perColumn: Bool) -> NoticeStripModifier {
        NoticeStripModifier(
            center: model.notices, model: model, also: actions?.notices,
            isShown: perColumn == (sizeClass == .compact)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .workingCopy:
            WorkingCopyView(model: model)
        case .history, .branch, .remoteBranch, .tag:
            HistoryView(model: model)
        case .stashes:
            StashListView(model: model)
        case .reflog:
            ReflogView(model: model)
        case .submodule(let name):
            SubmoduleView(model: model, name: name)
        case .worktree(let name):
            WorktreeView(model: model, name: name)
        case .pullRequests:
            PullRequestListView(model: model)
        case nil:
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .workingCopy:
            WorkingCopyDetailView(model: model)
        case .history, .branch, .remoteBranch, .tag:
            CommitDetailView(model: model, commitID: model.history.selection)
        case .stashes:
            CommitDetailView(model: model, commitID: model.selectedStash, emptyTitle: "No Stash Selected")
        case .reflog:
            CommitDetailView(model: model, commitID: model.history.reflog.selectedCommit, emptyTitle: "No Entry Selected")
        case .pullRequests:
            PullRequestDetailView(model: model)
        case .submodule, .worktree, nil:
            Color.clear
        }
    }
}
