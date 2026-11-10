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
/// | ⌘N | New Window (the system's) |
/// | ⌘O, ⇧⌘O | Add Repository…, Clone Repository… |
/// | ⌘K | Quick Open… |
/// | ⌘F | Find in History |
/// | ⌘1 to ⌘4 | Working Copy, History, Stashes, Reflog |
/// | ⌘R | Refresh |
/// | ⇧⌘F, ⇧⌘P, ⇧⌘U | Fetch, Pull, Push |
/// | ⇧⌘B, ⇧⌘M | New Branch…, Merge… |
/// | ⇧⌘S | Stash Changes… |
/// | ⇧⌘A, ⌥⇧⌘A | Stage All, Unstage All |
/// | ⌘↩ | Commit (as the composer's button) |
///
/// Destructive commands have none and keep their confirmations.
struct TwigCommands: Commands {
    @FocusedValue(RepositoryModel.self) private var model
    @FocusedValue(WindowActions.self) private var window

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Section {
                Button("Add Repository…") { window?.isAddingRepository = true }
                    .keyboardShortcut("o")
                    .disabled(window == nil)
                Button("Clone Repository…") { window?.isCloning = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(window == nil)
            }
            Section {
                Button("Quick Open…") { window?.quickOpen = .jump }
                    .keyboardShortcut("k")
                    .disabled(window == nil)
            }
            Section {
                Button("Close Repository") { window?.close() }
                    .disabled(model == nil)
            }
        }

        CommandGroup(before: .textEditing) {
            Button("Find in History") { model?.showHistorySearch() }
                .keyboardShortcut("f")
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
                Button("Refresh") {
                    Task { await model?.refresh() }
                }
                .keyboardShortcut("r")
                .disabled(model == nil)
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
            Button("Pull") { Task { await model?.pull() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(isTransferring || upstream == nil)
            Button("Push") { Task { await model?.push() } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(isTransferring || model?.currentBranch == nil || model?.hasRemotes != true)
            Button("Force Push…") { model?.remotes.isConfirmingForcePush = true }
                .disabled(isTransferring || upstream == nil)
            Button("Remotes…") { model?.remotes.isManagingRemotes = true }
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
