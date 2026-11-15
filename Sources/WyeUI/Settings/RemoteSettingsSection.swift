import Foundation
import GitKit
import SwiftUI

/// The app's defaults for fetching, kept in the user defaults.
enum FetchPreferences {
    static let backgroundIntervalKey = "fetch.backgroundInterval"
    static let backgroundOnExpensiveNetworksKey = "fetch.backgroundOnExpensiveNetworks"
    /// Set once notifications have been asked for, so turning background
    /// fetching off and on again does not ask again.
    static let askedForNotificationsKey = "fetch.askedForNotifications"

    static var backgroundInterval: BackgroundFetchInterval {
        BackgroundFetchInterval(rawValue: UserDefaults.standard.integer(forKey: backgroundIntervalKey)) ?? .off
    }

    /// Whether background fetches also run on cellular, hotspot and other
    /// networks the system marks expensive or constrained.
    static var fetchesOnExpensiveNetworks: Bool {
        UserDefaults.standard.bool(forKey: backgroundOnExpensiveNetworksKey)
    }
}

/// How often Wye fetches by itself, in minutes.
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

/// The Fetch, Pull and Push section of Settings: fetching in the
/// background, how a pull joins the branches and what happens to local
/// changes in the way, and whether a push takes the tags along. Whether a
/// fetch prunes is not a setting: it does, unless the Fetch sheet is told
/// otherwise for that one fetch.
struct RemoteSettingsSection: View {
    @AppStorage(FetchPreferences.backgroundIntervalKey) private var interval = BackgroundFetchInterval.off
    @AppStorage(FetchPreferences.backgroundOnExpensiveNetworksKey) private var onExpensiveNetworks = false
    @AppStorage(FetchPreferences.askedForNotificationsKey) private var askedForNotifications = false
    @AppStorage(RemotePreferences.pullModeKey) private var pullMode = PullMode.merge
    @AppStorage(RemotePreferences.autostashKey) private var autostash = AutostashPolicy.ask
    @AppStorage(PushPreferences.pushesAllTagsKey) private var pushesAllTags = true

    var body: some View {
        Section("Fetch, Pull and Push") {
            Picker("Fetch Automatically", selection: $interval) {
                ForEach(BackgroundFetchInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            Toggle("Also on Cellular and Low Data Networks", isOn: $onExpensiveNetworks)
                .disabled(interval == .off)
            Picker("Pull By", selection: $pullMode) {
                ForEach(PullMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("Stash Local Changes", selection: $autostash) {
                ForEach(AutostashPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            Toggle("Push All Tags", isOn: $pushesAllTags)
        }
        .onChange(of: interval) {
            guard interval != .off, !askedForNotifications else { return }
            askedForNotifications = true
            Task { await FetchNotifications.requestPermission() }
        }
    }
}
