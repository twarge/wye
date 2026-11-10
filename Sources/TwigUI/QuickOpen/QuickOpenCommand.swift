import SwiftUI

/// A command quick open can run: the ones in the menu bar that need no
/// further aim, so they can be found by name.
enum QuickOpenCommand: String, CaseIterable, Hashable {
    case showWorkingCopy, showHistory, showStashes, showReflog
    case fetch, pull, push, refresh
    case newBranch, merge, rebase
    case stageAll, unstageAll, stashChanges
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
        case .stageAll: "Stage All"
        case .unstageAll: "Unstage All"
        case .stashChanges: "Stash Changes…"
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
        case .stageAll: "plus.square.on.square"
        case .unstageAll: "minus.square"
        case .stashChanges: "tray.and.arrow.down"
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
        case .stageAll: Task { await model?.stageAll() }
        case .unstageAll: Task { await model?.unstageAll() }
        case .stashChanges: model?.showWorkingCopy(asking: .stashChanges)
        case .addRepository: window.isAddingRepository = true
        case .cloneRepository: window.isCloning = true
        case .closeRepository: window.close()
        }
    }
}
