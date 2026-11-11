import SwiftUI

/// A command quick open can run: the ones in the menu bar that need no
/// further aim, so they can be found by name.
enum QuickOpenCommand: String, CaseIterable, Hashable {
    case showWorkingCopy, showHistory, showStashes, showReflog
    case fetch, pull, push, refresh
    case newBranch, merge, rebase
    case checkOutRevision, resetToRevision, pushRevision
    case stageAll, unstageAll, stashChanges, createSnapshot
    case compareWorkingTreeToHead, compareWorkingTreeToIndex, compareIndexToHead
    case updateSubmodules, fetchSubmodules, addSubmodule, addWorktree
    case addRepository, cloneRepository, closeRepository

    var title: String {
        switch self {
        case .showWorkingCopy: "Show Working Copy"
        case .showHistory: "Show History"
        case .showStashes: "Show Stashes"
        case .showReflog: "Show Reflog"
        case .fetch: "Fetch"
        case .pull: "Pull"
        case .push: "Push"
        case .refresh: "Refresh"
        case .newBranch: "New Branch…"
        case .merge: "Merge…"
        case .rebase: "Rebase…"
        case .checkOutRevision: "Check Out Revision…"
        case .resetToRevision: "Reset to Revision…"
        case .pushRevision: "Push Revision To…"
        case .stageAll: "Stage All"
        case .unstageAll: "Unstage All"
        case .stashChanges: "Stash Changes…"
        case .createSnapshot: "Create Snapshot…"
        case .compareWorkingTreeToHead: "Compare Working Tree to HEAD"
        case .compareWorkingTreeToIndex: "Compare Working Tree to Index"
        case .compareIndexToHead: "Compare Index to HEAD"
        case .updateSubmodules: "Update All Submodules"
        case .fetchSubmodules: "Fetch All Submodules"
        case .addSubmodule: "Add Submodule…"
        case .addWorktree: "Add Worktree…"
        case .addRepository: "Add Repository…"
        case .cloneRepository: "Clone Repository…"
        case .closeRepository: "Close Repository"
        }
    }

    var systemImage: String {
        switch self {
        case .showWorkingCopy: "folder"
        case .showHistory: "clock.arrow.circlepath"
        case .showStashes: "tray.full"
        case .showReflog: "list.bullet.rectangle"
        case .fetch: "arrow.triangle.2.circlepath"
        case .pull: "arrow.down"
        case .push: "arrow.up"
        case .refresh: "arrow.clockwise"
        case .newBranch: "plus"
        case .merge: "arrow.triangle.merge"
        case .rebase: "arrow.triangle.branch"
        case .checkOutRevision: "arrow.uturn.down"
        case .resetToRevision: "arrow.counterclockwise"
        case .pushRevision: "arrow.up.to.line"
        case .createSnapshot: "camera"
        case .compareWorkingTreeToHead, .compareWorkingTreeToIndex, .compareIndexToHead: "arrow.left.arrow.right"
        case .stageAll: "plus.square.on.square"
        case .unstageAll: "minus.square"
        case .stashChanges: "tray.and.arrow.down"
        case .updateSubmodules: "arrow.down.circle"
        case .fetchSubmodules: "arrow.triangle.2.circlepath"
        case .addSubmodule: "shippingbox"
        case .addWorktree: "square.on.square"
        case .addRepository: "folder.badge.plus"
        case .cloneRepository: "square.and.arrow.down"
        case .closeRepository: "xmark"
        }
    }

    /// Whether the command works without a repository open in the window.
    var needsRepository: Bool {
        self != .addRepository && self != .cloneRepository
    }

    /// Runs the command as its menu item would.
    @MainActor
    func run(model: RepositoryModel?, window: WindowActions) {
        switch self {
        case .showWorkingCopy: model?.selection = .workingCopy
        case .showHistory: model?.selection = .history
        case .showStashes: model?.selection = .stashes
        case .showReflog: model?.selection = .reflog
        case .fetch: Task { await model?.fetch() }
        case .pull: Task { await model?.pull() }
        case .push: Task { await model?.push() }
        case .refresh: Task { await model?.refresh() }
        case .newBranch:
            if let commit = model?.newBranchStartingPoint { model?.present(.newBranch(at: commit)) }
        case .merge: window.quickOpen = .merge
        case .rebase: window.quickOpen = .rebase
        case .checkOutRevision: model?.present(.pickRevision(.checkOut))
        case .resetToRevision: model?.present(.pickRevision(.resetCurrentBranch))
        case .pushRevision: model?.present(.pickRevision(.pushRevision))
        case .createSnapshot: model?.present(.snapshot)
        case .compareWorkingTreeToHead: model?.present(.compareWorkingTree(.workingTreeToHead))
        case .compareWorkingTreeToIndex: model?.present(.compareWorkingTree(.workingTreeToIndex))
        case .compareIndexToHead: model?.present(.compareWorkingTree(.indexToHead))
        case .stageAll: Task { await model?.stageAll() }
        case .unstageAll: Task { await model?.unstageAll() }
        case .stashChanges: model?.showWorkingCopy(asking: .stashChanges)
        case .updateSubmodules: Task { await model?.updateSubmodules() }
        case .fetchSubmodules: Task { await model?.fetchSubmodules() }
        case .addSubmodule: model?.nested.sheet = .addSubmodule
        case .addWorktree: model?.nested.sheet = .addWorktree(nil)
        case .addRepository: window.isAddingRepository = true
        case .cloneRepository: window.isCloning = true
        case .closeRepository: window.close()
        }
    }
}
