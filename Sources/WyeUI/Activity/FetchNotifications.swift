import Foundation
import WyeShared
import UserNotifications

/// Local notifications for commits a background fetch brought, and the
/// repository to open when one is clicked.
enum FetchNotifications {
    static let repositoryKey = "repository"
    /// New commits that can be pulled from the notification itself.
    static let pullableCategory = "fetch.pullable"
    static let pullAction = "pull"
    static let openAction = "open"

    /// Asks once, when background fetching is first turned on.
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Becomes the notification centre's delegate, so clicks open the
    /// repository. Called once, as the app starts.
    @MainActor
    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationRouter.shared
        // Pull runs without bringing Wye forward; Open does what a click does.
        let pull = UNNotificationAction(
            identifier: pullAction, title: "Pull", options: [],
            icon: UNNotificationActionIcon(systemImageName: "arrow.down")
        )
        let open = UNNotificationAction(
            identifier: openAction, title: "Open", options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "folder")
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: pullableCategory, actions: [pull, open], intentIdentifiers: [])
        ])
    }

    /// Replaces a repository's notification with what became of the pull
    /// asked for from it.
    static func postPullOutcome(repository id: UUID, name: String, text: String) async {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = text
        content.threadIdentifier = id.uuidString
        content.userInfo = [repositoryKey: id.uuidString]
        let request = UNNotificationRequest(identifier: "fetch-\(id.uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Tells the user about new commits on a repository's upstream. One
    /// notification per repository replaces the one before, and they group
    /// by repository.
    static func post(repository id: UUID, name: String, branch: String?, upstream: String, count: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = count == 1
            ? "1 new commit on \(upstream)" + (branch.map { " to pull into \($0)" } ?? "") + "."
            : "\(count) new commits on \(upstream)" + (branch.map { " to pull into \($0)" } ?? "") + "."
        content.threadIdentifier = id.uuidString
        content.userInfo = [repositoryKey: id.uuidString]
        // Only a checked-out branch has somewhere to pull into.
        if branch != nil {
            content.categoryIdentifier = pullableCategory
        }
        let request = UNNotificationRequest(identifier: "fetch-\(id.uuidString)", content: content, trigger: nil)
        try? await center.add(request)
    }
}

/// Hands a clicked notification's repository to a window to open, as a
/// `wye://open` link would.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationRouter()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let text = response.notification.request.content.userInfo[FetchNotifications.repositoryKey] as? String
        guard let id = text.flatMap(UUID.init(uuidString:)) else { return }
        guard response.actionIdentifier == FetchNotifications.pullAction else {
            await MainActor.run { LinkRouter.shared.request(.openRepository(id)) }
            return
        }
        let name = response.notification.request.content.title
        let outcome: String
        do {
            outcome = try await RepositoryIntentRunner.pull(id)
        } catch let failure as IntentFailure {
            outcome = failure.message
        } catch {
            outcome = error.localizedDescription
        }
        await FetchNotifications.postPullOutcome(repository: id, name: name, text: outcome)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Shown while Wye is in front too: the window may be another repository's.
        [.banner, .list]
    }
}
