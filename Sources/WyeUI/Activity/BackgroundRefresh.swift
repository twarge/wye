import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Background fetching while the app is not in front, on iOS, through the
/// system's app refresh tasks. The system decides when it runs: the Fetch
/// setting's interval is only the earliest. macOS keeps the app running, so
/// `BackgroundFetcher`'s own schedule covers it there.
///
/// Registering needs the identifier in the app's Info.plist under
/// `BGTaskSchedulerPermittedIdentifiers` and `fetch` under
/// `UIBackgroundModes`; without them this does nothing, rather than
/// crashing as the scheduler would.
@MainActor
enum BackgroundRefresh {
    static let identifier = "com.twarge.app.twig.fetch"

    #if os(iOS)
    private static var isPermitted: Bool {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return permitted?.contains(identifier) == true
    }

    private static var library: RepositoryLibrary?
    private static var isRegistered = false

    /// Registers the task. Must run before the app finishes launching.
    static func register(library: RepositoryLibrary) {
        self.library = library
        guard isPermitted, !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { run(task) }
        }
    }

    /// Asks for the next run, when the app goes to the background.
    static func schedule() {
        guard isRegistered, let interval = FetchPreferences.backgroundInterval.seconds else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func run(_ task: BGAppRefreshTask) {
        // The next one first, so a run cut short still has a successor.
        schedule()
        guard let library else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            // The system gives about half a minute; stop starting new fetches well before.
            await BackgroundFetcher.shared.runDue(in: library, deadline: .now + 20)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
    #else
    static func register(library: RepositoryLibrary) {}
    static func schedule() {}
    #endif
}
