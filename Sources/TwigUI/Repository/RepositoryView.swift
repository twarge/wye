import GitKit
import SwiftUI

/// A repository window: sidebar, a list for what the sidebar selects, and the
/// detail of what that list selects.
struct RepositoryView: View {
    @Bindable var model: RepositoryModel
    var close: () -> Void

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button("Repositories", systemImage: "square.grid.2x2", action: close)
                            .help("Show all repositories")
                    }
                }
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 320, ideal: 500)
                // The window stands for the repository's folder: on macOS the
                // title gets the folder's icon, to drag, and a menu of the
                // folders that enclose it.
                .navigationDocument(model.repository.url)
                // On the content column, so it shows whatever the sidebar selects.
                .remoteControls(for: model)
                .undoControls(for: model)
        } detail: {
            detail
        }
        .focusedSceneValue(model)
        // For diffs that read more than their lines, such as images.
        .environment(\.diffRepository, model.repository)
        .repositoryWindowServices(model)
        .alert(for: $model.error)
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
        .task(id: model.selection) {
            if let scope = model.selection?.historyScope {
                await model.history.show(scope)
            }
        }
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
