import Foundation
import GitKit
#if os(iOS)
import BackgroundTasks
#endif

/// How far a whole network operation has got, as one number: its phases
/// each count from nothing, and a progress bar should not go back.
enum ContinuedProgress {
    /// The scale `units(for:)` counts on.
    static let total: Int64 = 1000

    /// The share of the bar each phase fills: where it starts and ends.
    static func span(of phase: TransferProgress.Phase) -> ClosedRange<Double> {
        switch phase {
        case .connecting: 0...0.02
        case .receivingObjects: 0.02...0.7
        case .resolvingDeltas: 0.7...0.9
        case .checkingOut: 0.9...1
        case .countingObjects: 0.02...0.1
        case .sendingObjects: 0.1...1
        }
    }

    static func units(for progress: TransferProgress) -> Int64 {
        let span = span(of: progress.phase)
        let fraction = progress.fractionCompleted ?? 0
        let overall = span.lowerBound + (span.upperBound - span.lowerBound) * fraction
        return Int64((overall * Double(total)).rounded())
    }
}

/// Lets a clone, fetch, pull or push the user started carry on when the app
/// leaves the screen, on iOS, with its progress on the Lock Screen and in
/// the Dynamic Island: the system's continued processing tasks, which draw
/// that Live Activity themselves and offer the user a way to stop the work.
///
/// Asking is always safe. Where the system has no room, on macOS, or
/// without the identifier in the app's Info.plist, `begin` returns a handle
/// that does nothing and the work runs as it always did.
@MainActor
enum ContinuedWork {
    /// One piece of work the system may be keeping alive.
    @MainActor
    final class Handle {
        fileprivate let identifier: String
        fileprivate let title: String
        fileprivate let cancel: @Sendable () -> Void
        fileprivate var isFinished = false
        fileprivate var units: Int64 = 0
        fileprivate var subtitle: String
        #if os(iOS)
        fileprivate var task: BGContinuedProcessingTask?
        #endif

        fileprivate init(identifier: String, title: String, subtitle: String, cancel: @escaping @Sendable () -> Void) {
            self.identifier = identifier
            self.title = title
            self.subtitle = subtitle
            self.cancel = cancel
        }

        /// Shows where a transfer has got to. The bar never goes back, so a
        /// retry after signing in carries on from where the first try stopped.
        func report(_ progress: TransferProgress) {
            report(units: ContinuedProgress.units(for: progress), subtitle: progress.summary)
        }

        /// Shows progress through several things: repository 3 of 12.
        func report(completed: Int, of total: Int, subtitle: String) {
            let fraction = total > 0 ? Double(completed) / Double(total) : 0
            report(units: Int64(fraction * Double(ContinuedProgress.total)), subtitle: subtitle)
        }

        private func report(units: Int64, subtitle: String) {
            guard !isFinished else { return }
            self.units = max(self.units, min(units, ContinuedProgress.total))
            self.subtitle = subtitle
            #if os(iOS)
            push()
            #endif
        }

        /// Tells the system the work is over. Safe to call more than once.
        func finish(success: Bool) {
            guard !isFinished else { return }
            isFinished = true
            #if os(iOS)
            if success { task?.progress.completedUnitCount = ContinuedProgress.total }
            task?.setTaskCompleted(success: success)
            task = nil
            ContinuedWork.handles[identifier] = nil
            #endif
        }

        #if os(iOS)
        fileprivate func push() {
            guard let task else { return }
            task.progress.completedUnitCount = units
            if task.subtitle != subtitle {
                task.updateTitle(title, subtitle: subtitle)
            }
        }
        #endif
    }

    /// Starts keeping a piece of work alive. `cancel` stops the work; the
    /// system calls it when the user stops the task or its time runs out.
    static func begin(_ title: String, subtitle: String, cancel: @escaping @Sendable () -> Void) -> Handle {
        let handle = Handle(
            identifier: prefix + "." + UUID().uuidString, title: title, subtitle: subtitle, cancel: cancel
        )
        #if os(iOS)
        guard isRegistered else { return handle }
        let request = BGContinuedProcessingTaskRequest(identifier: handle.identifier, title: title, subtitle: subtitle)
        // No queue: work that cannot be kept alive now simply runs as it
        // would have, rather than waiting its turn.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            handles[handle.identifier] = handle
        } catch {
            // No room, or not supported here.
        }
        #endif
        return handle
    }

    /// The identifiers' prefix: the app's bundle identifier, as the system
    /// wants, then what the work is.
    static var prefix: String {
        (Bundle.main.bundleIdentifier ?? "com.twarge.app.wye") + ".transfer"
    }

    /// The identifier the Info.plist has to permit.
    static var wildcard: String { prefix + ".*" }

    #if os(iOS)
    fileprivate static var handles: [String: Handle] = [:]
    private static var isRegistered = false

    private static var isPermitted: Bool {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return permitted?.contains(wildcard) == true
    }

    /// Registers the tasks' handler. Must run before the app finishes launching.
    static func register() {
        guard isPermitted, !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: wildcard, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { adopt(task) }
        }
    }

    /// The system has started a task asked for in `begin`.
    private static func adopt(_ task: BGContinuedProcessingTask) {
        guard let handle = handles[task.identifier], !handle.isFinished else {
            // The work ended before the system got to it.
            task.setTaskCompleted(success: true)
            return
        }
        task.progress.totalUnitCount = ContinuedProgress.total
        let cancel = handle.cancel
        task.expirationHandler = { cancel() }
        handle.task = task
        handle.push()
    }
    #else
    static func register() {}
    #endif
}
