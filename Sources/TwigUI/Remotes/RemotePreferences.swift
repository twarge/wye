import Foundation
import GitKit
import SwiftUI

/// What to do when local changes would block or complicate a pull, a
/// checkout, a merge or a rebase.
enum AutostashPolicy: String, CaseIterable, Identifiable {
    /// Offer to stash them when they get in the way.
    case ask
    /// Stash them first whenever there are any.
    case always
    /// Leave them alone; the operation refuses if they are in the way.
    case never

    var id: Self { self }

    var title: String {
        switch self {
        case .ask: "Ask When They’re in the Way"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

/// The app's defaults for pulling, kept in the user defaults. A
/// repository's own `pull.rebase` and `pull.ff` come before them.
enum RemotePreferences {
    static let pullModeKey = "pullMode"
    static let autostashKey = "autostash"

    static var pullMode: PullMode {
        UserDefaults.standard.string(forKey: pullModeKey).flatMap(PullMode.init(rawValue:)) ?? .merge
    }

    static var autostash: AutostashPolicy {
        UserDefaults.standard.string(forKey: autostashKey).flatMap(AutostashPolicy.init(rawValue:)) ?? .ask
    }
}

extension PullMode {
    var title: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .fastForwardOnly: "Fast-Forward Only"
        }
    }

    var explanation: String {
        switch self {
        case .merge:
            "Moves the branch forward when it has no commits of its own; otherwise a merge commit joins the two."
        case .rebase:
            "Moves the branch forward when it can; otherwise replays its own commits on top of the pulled ones, keeping the history in one line."
        case .fastForwardOnly:
            "Only moves the branch forward, and refuses when both sides have commits of their own."
        }
    }
}

/// The Pull section of Settings: how a pull joins the branches, and what
/// happens to local changes in the way.
struct PullSettingsSection: View {
    @AppStorage(RemotePreferences.pullModeKey) private var pullMode = PullMode.merge
    @AppStorage(RemotePreferences.autostashKey) private var autostash = AutostashPolicy.ask

    var body: some View {
        Section {
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
        } header: {
            Text("Pull")
        } footer: {
            Text("\(pullMode.explanation) A repository whose configuration sets pull.rebase or pull.ff uses that instead. "
                 + "Stashed changes are put back after a pull, checkout, merge or rebase.")
        }
    }
}
