import Foundation
import SwiftUI

/// The app's defaults for pushing, kept in the user defaults. A repository
/// can set its own choice over `pushesAllTags`, in its settings.
enum PushPreferences {
    static let pushesAllTagsKey = "push.allTags"
    static let pushesNewTagsKey = "tag.pushToAllRemotes"

    /// Whether pushing a branch takes every local tag along, as
    /// `git push --tags` does. On unless turned off.
    static func pushesAllTags(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: pushesAllTagsKey) as? Bool ?? true
    }

    /// The New Tag sheet's last choice of pushing the tag to every remote.
    /// On until the user turns it off.
    static func pushesNewTags(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: pushesNewTagsKey) as? Bool ?? true
    }

    static func setPushesNewTags(_ pushes: Bool, defaults: UserDefaults = .standard) {
        defaults.set(pushes, forKey: pushesNewTagsKey)
    }
}

/// The Push section of Settings: whether a push takes the tags along.
struct PushSettingsSection: View {
    @AppStorage(PushPreferences.pushesAllTagsKey) private var pushesAllTags = true

    var body: some View {
        Section {
            Toggle("Push All Tags", isOn: $pushesAllTags)
        } header: {
            Text("Push")
        } footer: {
            Text("Pushing a branch also sends every tag in the repository to the same remote, so tags made "
                 + "without pushing them get there too. A tag the remote already has on another commit is left as "
                 + "it is, and you’re told; tags are never forced, not even by a force push. "
                 + "A repository’s own settings can choose otherwise.")
        }
    }
}
