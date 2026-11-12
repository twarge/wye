import GitKit
import SwiftUI

/// A request from the menu bar for something a view keeps to itself: a
/// sheet or confirmation it presents, or focus it holds. The view takes it
/// when it appears or when the request arrives, whichever is later, so the
/// menu can switch to the view and ask in one go.
@MainActor
@Observable
final class ViewRequests {
    enum Request: Hashable {
        case stashChanges
        case discardAllChanges
        case searchHistory
    }

    private(set) var pending: Request?

    func ask(_ request: Request) {
        pending = request
    }

    /// Whether `request` is pending, clearing it if so.
    func take(_ request: Request) -> Bool {
        guard pending == request else { return false }
        pending = nil
        return true
    }
}

/// The menu bar, which on iPad is also the list of keyboard shortcuts.
///
/// Shortcuts, chosen to stay clear of the system's and each other's:
///
/// | Keys | Command |
/// | --- | --- |
/// | ⌘N, ⌘T | New Window (the system's), New Tab |
/// | ⌘O, ⌥⌘O | Add Repository…, Clone Repository… |
/// | ⌃⌘N | New Repository… |
/// | ⌘[, ⌘] | Back, Forward |
/// | ⇧⌘O | Quick Open… |
/// | ⌥⇧⌘P, ⇧⌘R | Pull All Repositories, Review |
/// | ⌘F | Find in the diff or file that has focus, otherwise Find in History |
/// | ⌘G, ⇧⌘G | Find Next, Find Previous |
/// | ⌘Z, ⇧⌘Z | Undo, Redo (the text's while a field has focus) |
/// | ⌘1 to ⌘4 | Working Copy, History, Stashes, Reflog |
/// | ⌘0 | Show HEAD |
/// | ⌘R | Refresh |
/// | ⇧⌘F, ⇧⌘P, ⇧⌘U | Fetch, Pull, Push |
/// | ⇧⌘B, ⇧⌘M | New Branch…, Merge… |
/// | ⇧⌘S | Stash Changes… |
/// | ⇧⌘A, ⌥⇧⌘A | Stage All, Unstage All |
/// | ⌘↩ | Commit (as the composer's button) |
///
/// Destructive commands have none and keep their confirmations.
struct WyeCommands: Commands {
    var library: RepositoryLibrary

    @FocusedValue(RepositoryModel.self) private var model
    @FocusedValue(WindowActions.self) private var window
    @FocusedValue(\.findModel) private var find
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            if Platform.hasWindowTabs {
                Button("New Tab") {
                    Platform.openAsTab { openWindow(id: WyeScene.windowID) }
                }
                .keyboardShortcut("t")
            }
            Section {
                Button("Add Repository…") { window?.isAddingRepository = true }
                    .keyboardShortcut("o")
                    .disabled(window == nil)
                Button("Clone Repository…") { window?.isCloning = true }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    .disabled(window == nil)
                Button("New Repository…") { window?.isCreatingRepository = true }
                    .keyboardShortcut("n", modifiers: [.command, .control])
                    .disabled(window == nil)
                OpenRecentMenu(library: library, window: window)
            }
            Section {
                Button("Quick Open…") { window?.quickOpen = .jump }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(window == nil)
            }
            Section {
                Button("Pull All Repositories") { window?.isPullingAll = true }
                    .keyboardShortcut("p", modifiers: [.command, .option, .shift])
                    .disabled(window == nil || library.listedBookmarks.isEmpty)
                Button("Review Uncommitted and Unpushed") {
                    window?.close()
                    window?.isReviewing = true
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(window == nil)
            }
            Section {
                Button("Close Repository") { window?.close() }
                    .disabled(model == nil)
            }
        }

        UndoCommands(model: model)
        HistoryCommands(model: model)

        CommandGroup(before: .textEditing) {
            FindMenuItems(find: find)
            Button("Find in History") { model?.showHistorySearch() }
                .keyboardShortcut(find == nil ? KeyboardShortcut("f") : nil)
                .disabled(model == nil)
            Divider()
        }

        CommandGroup(before: .toolbar) {
            Section {
                show("Working Copy", .workingCopy, key: "1")
                show("History", .history, key: "2")
                show("Stashes", .stashes, key: "3")
                show("Reflog", .reflog, key: "4")
            }
            Section {
                Button("Back") {
                    if let model { Task { await model.windowState.navigation.goBack(in: model) } }
                }
                .keyboardShortcut("[")
                .disabled(model?.windowState.navigation.canGoBack != true)
                Button("Forward") {
                    if let model { Task { await model.windowState.navigation.goForward(in: model) } }
                }
                .keyboardShortcut("]")
                .disabled(model?.windowState.navigation.canGoForward != true)
            }
            Section {
                Button("Refresh") {
                    Task { await model?.refresh() }
                }
                .keyboardShortcut("r")
                .disabled(model == nil)
            }
        }

        CommandGroup(after: .windowArrangement) {
            Section {
                Button("Activity") {
                    if Platform.hasAuxiliaryWindows {
                        openWindow(id: WyeScene.activityWindowID)
                    } else {
                        window?.isShowingActivity = true
                    }
                }
                .disabled(!Platform.hasAuxiliaryWindows && window == nil)
            }
        }

        CommandMenu("Repository") {
            RepositoryMenu(model: model, window: window)
        }

        CommandMenu("Working Copy") {
            WorkingCopyMenu(model: model)
        }
    }

    private func show(_ title: String, _ item: SidebarItem, key: KeyEquivalent) -> some View {
        Button(title) { model?.selection = item }
            .keyboardShortcut(key)
            .disabled(model == nil)
    }
}

private struct RepositoryMenu: View {
    var model: RepositoryModel?
    var window: WindowActions?

    var body: some View {
        let isTransferring = model?.remotes.activity != nil
        let upstream = model?.currentBranch?.upstream
        Section {
            Button("Fetch") { Task { await model?.fetch() } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(isTransferring || model?.hasRemotes != true)
            Button("Fetch…") { model?.remotes.sheet = .fetchOptions }
                .disabled(isTransferring || model?.hasRemotes != true)
            Button("Pull") { Task { await model?.pull() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(isTransferring || upstream == nil)
            Button("Pull…") { model?.remotes.sheet = .pullOptions }
                .disabled(isTransferring || model?.headBranchName == nil || model?.hasRemotes != true)
            Button("Sync") { Task { await model?.sync() } }
                .disabled(isTransferring || upstream == nil)
            Button("Push") { Task { await model?.push() } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(isTransferring || model?.currentBranch == nil || model?.hasRemotes != true)
            Button("Push to…") { model?.remotes.sheet = .pushTo(branch: model?.snapshot?.head.branchName) }
                .disabled(isTransferring || model?.hasRemotes != true)
            Button("Push Revision To…") { model?.present(.pickRevision(.pushRevision)) }
                .disabled(isTransferring || model?.hasRemotes != true)
            Button("Force Push…") { model?.remotes.isConfirmingForcePush = true }
                .disabled(isTransferring || upstream == nil)
            Button("Remotes…") { model?.remotes.isManagingRemotes = true }
                .disabled(model == nil)
            Button("Repository Settings…") { model?.windowState.isShowingSettings = true }
                .disabled(model == nil)
        }
        Section {
            Button("New Branch…") {
                if let commit = model?.newBranchStartingPoint { model?.present(.newBranch(at: commit)) }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(model?.newBranchStartingPoint == nil)
            Button("Merge…") { window?.quickOpen = .merge }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model?.canStartMerge != true)
            Button("Rebase…") { window?.quickOpen = .rebase }
                .disabled(model?.canStartMerge != true || model?.headBranchName == nil)
            RebaseMenuItems(model: model)
        }
        Section {
            Button("Check Out Revision…") { model?.present(.pickRevision(.checkOut)) }
                .disabled(model?.snapshot == nil || model?.isBusy != false)
            Button("Reset to Revision…") { model?.present(.pickRevision(.resetCurrentBranch)) }
                .disabled(model?.snapshot?.head.target == nil)
            Button("Merge With Revision…") { model?.present(.pickRevision(.merge)) }
                .disabled(model?.canStartMerge != true)
            Button("Rebase On Revision…") { model?.present(.pickRevision(.rebase)) }
                .disabled(model?.canStartMerge != true || model?.headBranchName == nil)
        }
        Section {
            AllSubmodulesActions(model: model)
        }
        Section {
            AllWorktreesActions(model: model)
        }
        Section {
            Button("Stash Changes…") { model?.showWorkingCopy(asking: .stashChanges) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model?.workingCopy.entries.isEmpty ?? true)
        }
    }
}

private struct WorkingCopyMenu: View {
    var model: RepositoryModel?

    var body: some View {
        let workingCopy = model?.workingCopy
        Section {
            Button("Stage All") { Task { await model?.stageAll() } }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(workingCopy?.entries.contains { $0.unstaged != nil } != true)
            Button("Unstage All") { Task { await model?.unstageAll() } }
                .keyboardShortcut("a", modifiers: [.command, .shift, .option])
                .disabled(workingCopy?.hasStagedChanges != true)
        }
        Section {
            Button(workingCopy?.isAmending == true ? "Amend Last Commit" : "Commit") {
                Task { await model?.commitOrAmend() }
            }
            .keyboardShortcut(.return)
            .disabled(workingCopy?.canCommitOrAmend != true)
            Toggle("Amend Last Commit", isOn: Binding {
                model?.workingCopy.isAmending ?? false
            } set: { isAmending in
                Task { await model?.setAmending(isAmending) }
            })
            .disabled(model == nil || (workingCopy?.isAmending != true && model?.canAmend != true))
        }
        Section {
            Button("Create Snapshot…") { model?.present(.snapshot) }
                .disabled(workingCopy?.entries.isEmpty != false || model?.isBusy != false)
            WorkingTreeCompareMenu(model: model)
        }
        Section {
            Button("Discard All Changes…") { model?.showWorkingCopy(asking: .discardAllChanges) }
                .disabled(workingCopy?.hasUnstagedChanges != true)
        }
    }
}

extension RepositoryModel {
    /// Where the menu's New Branch starts: the commit selected in the
    /// history while it shows, otherwise `HEAD`.
    var newBranchStartingPoint: OID? {
        if selection?.historyScope != nil, let selected = history.selection {
            return selected
        }
        return snapshot?.head.target
    }

    /// Whether a merge or rebase can begin: there are commits, and no other
    /// operation is under way.
    var canStartMerge: Bool {
        snapshot?.head.target != nil && (snapshot?.state ?? .clean) == .clean
    }

    /// Shows the working copy and asks it for one of its sheets or confirmations.
    func showWorkingCopy(asking request: ViewRequests.Request) {
        selection = .workingCopy
        viewRequests.ask(request)
    }

    /// Shows a history, keeping the one on screen if there is one, and puts
    /// the cursor in its search field.
    func showHistorySearch() {
        if selection?.historyScope == nil {
            selection = .history
        }
        viewRequests.ask(.searchHistory)
    }
}
