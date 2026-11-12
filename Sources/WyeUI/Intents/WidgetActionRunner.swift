import Foundation
import WyeShared
import notify

/// Does what the widgets and the Fetch All control ask for: the same
/// operations as the Shortcuts actions, with the outcome in the activity
/// log rather than said aloud. The status file is written as each
/// finishes, which is what the widgets then show.
@MainActor
enum WidgetActionRunner {
    /// Takes the widgets' requests from now on. Call once, as the app starts.
    static func install() {
        WidgetActions.handler = { action in await run(action) }
        // A request left by the widget extension's own process, while the
        // app is running: on the Mac, where the widgets' intents run there.
        var token: Int32 = 0
        notify_register_dispatch(WidgetActions.pendingNotification, &token, .main) { _ in
            MainActor.assumeIsolated { runPending() }
        }
    }

    /// Runs what was asked while the app was not there to hear it.
    static func runPending() {
        let actions = WidgetActions.take()
        guard !actions.isEmpty else { return }
        Task {
            for action in actions { await run(action) }
        }
    }

    static func run(_ action: WidgetAction) async {
        let library = RepositoryLibrary.shared
        func name(_ id: UUID) -> String? { library.bookmarks.first { $0.id == id }?.name }
        switch action {
        case .fetchAll:
            let entry = ActivityLog.shared.begin("Fetch All", repository: nil, isBackground: true)
            _ = await RepositoryIntentRunner.fetchAll()
            ActivityLog.shared.finish(entry, error: nil)
        case .fetch(let id):
            let entry = ActivityLog.shared.begin("Fetch", repository: name(id), isBackground: true)
            do {
                _ = try await RepositoryIntentRunner.fetch(id)
                ActivityLog.shared.finish(entry, error: nil)
            } catch {
                ActivityLog.shared.finish(entry, error: error)
            }
        case .pull(let id):
            let entry = ActivityLog.shared.begin("Pull", repository: name(id), isBackground: true)
            do {
                _ = try await RepositoryIntentRunner.pull(id)
                ActivityLog.shared.finish(entry, error: nil)
            } catch {
                ActivityLog.shared.finish(entry, error: error)
            }
        }
    }
}
