import AppIntents
import WyeUI

// In the app target: App Shortcuts phrases in a package are not taken into
// the app's metadata, while the intents themselves are.

/// The phrases Siri knows without any setup: "Pull Horizontal in Wye".
/// Siri learns the repository names from `updateAppShortcutParameters()`,
/// which `IntentsSupport` has it called whenever the list changes.
struct WyeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PullRepositoryIntent(),
            phrases: [
                "Pull \(\.$repository) in \(.applicationName)",
                "Pull \(\.$repository) with \(.applicationName)",
                "Pull in \(.applicationName)"
            ],
            shortTitle: "Pull",
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: PushRepositoryIntent(),
            phrases: [
                "Push \(\.$repository) in \(.applicationName)",
                "Push \(\.$repository) with \(.applicationName)",
                "Push in \(.applicationName)"
            ],
            shortTitle: "Push",
            systemImageName: "arrow.up.circle"
        )
        AppShortcut(
            intent: FetchRepositoryIntent(),
            phrases: [
                "Fetch \(\.$repository) in \(.applicationName)",
                "Fetch \(\.$repository) with \(.applicationName)"
            ],
            shortTitle: "Fetch",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: FetchAllRepositoriesIntent(),
            phrases: [
                "Fetch all repositories in \(.applicationName)",
                "Fetch everything in \(.applicationName)"
            ],
            shortTitle: "Fetch All",
            systemImageName: "arrow.triangle.2.circlepath.circle"
        )
        AppShortcut(
            intent: GetRepositoryStatusIntent(),
            phrases: [
                "What’s the status of \(\.$repository) in \(.applicationName)",
                "Get the status of \(\.$repository) in \(.applicationName)",
                "\(.applicationName) status of \(\.$repository)"
            ],
            shortTitle: "Status",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: OpenRepositoryIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)"
            ],
            shortTitle: "Open Repository",
            systemImageName: "folder"
        )
    }
}

