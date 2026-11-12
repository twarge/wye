#if os(macOS)
import AppKit
import SwiftUI
import WyeShared

/// Wye in the menu bar, on macOS, for those who turn it on: the
/// repositories with work to push or commits to pull, a click from being
/// opened, and Fetch All and Pull All without a window.
struct MenuBarStatus: Scene {
    var library: RepositoryLibrary
    @AppStorage(MenuBarPreferences.isShownKey) private var isShown = false

    var body: some Scene {
        MenuBarExtra(isInserted: $isShown) {
            MenuBarStatusMenu(library: library)
        } label: {
            let count = MenuBarStatusList(
                library.listedBookmarks.map(\.id), summaries: RepositoryStatusBoard.shared.summaries
            ).attention.count
            Label {
                Text(count == 0 ? "Wye" : "Wye, \(count) repositories need attention")
            } icon: {
                Image(systemName: count == 0 ? "arrow.triangle.branch" : "arrow.up.arrow.down.circle")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

enum MenuBarPreferences {
    static let isShownKey = "menuBar.isShown"
}

/// Which repositories the menu lists, and in what order.
struct MenuBarStatusList {
    /// Those with commits to push or pull or changes to commit, most
    /// recently updated first.
    var attention: [RepositoryStatusSummary]

    static let limit = 12

    init(_ listed: [UUID], summaries: [UUID: RepositoryStatusSummary]) {
        attention = listed.compactMap { summaries[$0] }
            .filter { $0.hasUnpushedWork || $0.behind > 0 }
            .sorted { first, second in
                if first.updated != second.updated { return first.updated > second.updated }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    /// "Wye — main ↑2 ↓1 ✎": a row's title, the counts only where there are any.
    static func title(for summary: RepositoryStatusSummary) -> String {
        var parts = [summary.name]
        if let branch = summary.branch { parts.append("— \(branch)") }
        if summary.ahead > 0 { parts.append("↑\(summary.ahead)") }
        if summary.behind > 0 { parts.append("↓\(summary.behind)") }
        if summary.hasUncommittedChanges { parts.append("✎") }
        return parts.joined(separator: " ")
    }
}

private struct MenuBarStatusMenu: View {
    var library: RepositoryLibrary
    @Environment(\.openWindow) private var openWindow
    @State private var pullAll = PullAllModel()

    var body: some View {
        let list = MenuBarStatusList(library.listedBookmarks.map(\.id), summaries: RepositoryStatusBoard.shared.summaries)
        if list.attention.isEmpty {
            Text(library.listedBookmarks.isEmpty ? "No Repositories" : "Everything Is Pushed and Up to Date")
        } else {
            Section("Needs Attention") {
                ForEach(list.attention.prefix(MenuBarStatusList.limit)) { summary in
                    Button(MenuBarStatusList.title(for: summary)) { open(summary.id) }
                        .accessibilityLabel("\(summary.name), \(summary.unpushedDescription)")
                }
                if list.attention.count > MenuBarStatusList.limit {
                    Text("and \(list.attention.count - MenuBarStatusList.limit) more")
                }
            }
        }
        Divider()
        Button("Fetch All") {
            Task { await WidgetActionRunner.run(.fetchAll) }
        }
        .disabled(library.listedBookmarks.isEmpty)
        Button(pullAll.isRunning ? "Pulling \(pullAll.finishedCount) of \(pullAll.results.count)…" : "Pull All") {
            pullAll.start(library.listedBookmarks)
        }
        .disabled(library.listedBookmarks.isEmpty || pullAll.isRunning)
        if !pullAll.isRunning, !pullAll.results.isEmpty {
            Text("Last Pull All: " + PullAllReport.summary(of: pullAll.results))
            ForEach(pullAll.problems) { problem in
                Button("Open \(problem.name)…") { open(problem.id) }
            }
        }
        Divider()
        Button("Open Wye") { showWindow() }
        Button("Quit Wye") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Opens a repository in a window: the front one when there is one,
    /// otherwise a new one that picks it up as it appears.
    private func open(_ id: UUID) {
        if hasWindow {
            LinkRouter.shared.request(.openRepository(id))
        } else {
            library.openInNextWindow = id
            openWindow(id: WyeScene.windowID)
        }
        NSApplication.shared.activate()
    }

    private func showWindow() {
        if !hasWindow { openWindow(id: WyeScene.windowID) }
        NSApplication.shared.activate()
    }

    private var hasWindow: Bool {
        NSApplication.shared.windows.contains { $0.isVisible && $0.canBecomeMain }
    }
}
#endif
