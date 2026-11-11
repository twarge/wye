import Foundation
import SwiftUI

/// The app's defaults for fetching, kept in the user defaults.
enum FetchPreferences {
    static let pruneKey = "fetch.prune"
    static let backgroundIntervalKey = "fetch.backgroundInterval"
    static let backgroundOnExpensiveNetworksKey = "fetch.backgroundOnExpensiveNetworks"
    /// Set once notifications have been asked for, so turning background
    /// fetching off and on again does not ask again.
    static let askedForNotificationsKey = "fetch.askedForNotifications"

    /// Whether a fetch removes remote branches that are gone from the remote.
    static var prune: Bool {
        UserDefaults.standard.object(forKey: pruneKey) as? Bool ?? true
    }

    static var backgroundInterval: BackgroundFetchInterval {
        BackgroundFetchInterval(rawValue: UserDefaults.standard.integer(forKey: backgroundIntervalKey)) ?? .off
    }

    /// Whether background fetches also run on cellular, hotspot and other
    /// networks the system marks expensive or constrained.
    static var fetchesOnExpensiveNetworks: Bool {
        UserDefaults.standard.bool(forKey: backgroundOnExpensiveNetworksKey)
    }
}

/// How often Twig fetches by itself, in minutes.
enum BackgroundFetchInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case hourly = 60

    var id: Self { self }

    var seconds: TimeInterval? {
        self == .off ? nil : TimeInterval(rawValue * 60)
    }

    var title: String {
        switch self {
        case .off: "Never"
        case .hourly: "Every Hour"
        default: "Every \(rawValue) Minutes"
        }
    }
}

/// The Fetch section of Settings: pruning, and fetching in the background.
struct FetchSettingsSection: View {
    @AppStorage(FetchPreferences.pruneKey) private var prune = true
    @AppStorage(FetchPreferences.backgroundIntervalKey) private var interval = BackgroundFetchInterval.off
    @AppStorage(FetchPreferences.backgroundOnExpensiveNetworksKey) private var onExpensiveNetworks = false
    @AppStorage(FetchPreferences.askedForNotificationsKey) private var askedForNotifications = false

    var body: some View {
        Section {
            Toggle("Remove Deleted Remote Branches", isOn: $prune)
            Picker("Fetch Automatically", selection: $interval) {
                ForEach(BackgroundFetchInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            Toggle("Also on Cellular and Low Data Networks", isOn: $onExpensiveNetworks)
                .disabled(interval == .off)
        } header: {
            Text("Fetch")
        } footer: {
            Text("While Twig is open it fetches each repository’s default remote on this schedule, quietly: "
                 + "a remote that wants a token or key Twig doesn’t have is skipped, and a repository busy with "
                 + "another operation waits. A notification tells you when new commits arrive for the branch you have checked out.")
        }
        .onChange(of: interval) {
            guard interval != .off, !askedForNotifications else { return }
            askedForNotifications = true
            Task { await FetchNotifications.requestPermission() }
        }
    }
}

/// The New Repositories section of Settings.
struct NewRepositorySettingsSection: View {
    @AppStorage(NewRepositoryPreferences.defaultBranchKey) private var defaultBranch = NewRepositoryPreferences.standardBranch

    var body: some View {
        Section {
            TextField("Default Branch Name", text: $defaultBranch, prompt: Text(NewRepositoryPreferences.standardBranch))
                .autocorrectionDisabled()
                .noAutocapitalization()
        } header: {
            Text("New Repositories")
        } footer: {
            Text("The branch a repository created in Twig starts on.")
        }
    }
}

enum NewRepositoryPreferences {
    static let defaultBranchKey = "newRepository.defaultBranch"
    static let standardBranch = "main"

    static var defaultBranch: String {
        let saved = UserDefaults.standard.string(forKey: defaultBranchKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty ? standardBranch : saved
    }
}
