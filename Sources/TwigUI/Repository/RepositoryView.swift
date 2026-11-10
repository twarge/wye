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
                // On the content column, so it shows whatever the sidebar selects.
                .remoteControls(for: model)
        } detail: {
            detail
        }
        .focusedSceneValue(model)
        .alert(for: $model.error)
        .branchingSheets(model)
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
            SubmoduleView(submodule: model.snapshot?.submodules.first { $0.name == name })
        case .worktree(let name):
            WorktreeView(worktree: model.snapshot?.worktrees.first { $0.name == name })
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
        case .submodule, .worktree, nil:
            Color.clear
        }
    }
}

private struct SubmoduleView: View {
    var submodule: Submodule?

    var body: some View {
        if let submodule {
            Form {
                LabeledContent("Path", value: submodule.path)
                LabeledContent("URL", value: submodule.url ?? "None")
                LabeledContent("Commit") {
                    Text(submodule.headID?.abbreviated() ?? "Not committed")
                        .font(.code)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(submodule.name)
        }
    }
}

private struct WorktreeView: View {
    var worktree: Worktree?

    var body: some View {
        if let worktree {
            Form {
                LabeledContent("Path", value: worktree.path)
                LabeledContent("Locked", value: worktree.isLocked ? "Yes" : "No")
            }
            .formStyle(.grouped)
            .navigationTitle(worktree.name)
        }
    }
}
