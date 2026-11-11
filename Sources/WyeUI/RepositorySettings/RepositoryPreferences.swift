import Foundation
import GitKit

/// What one repository sets for itself in Wye, over the app's defaults,
/// where git's own configuration has no place for it. Kept in the user
/// defaults by the repository list's bookmark id.
///
/// How a repository pulls is not here: that is `pull.rebase` and `pull.ff`
/// in its own git configuration, which git reads too.
enum RepositoryPreferences {
    private static func key(_ name: String, _ id: UUID) -> String {
        "repository.\(id.uuidString).\(name)"
    }

    /// The remote fetches, publishing and background fetches use when the
    /// current branch's upstream does not say; `nil` to choose as usual.
    static func defaultRemote(for id: UUID, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key("defaultRemote", id))
    }

    static func setDefaultRemote(_ remote: String?, for id: UUID, defaults: UserDefaults = .standard) {
        defaults.set(remote, forKey: key("defaultRemote", id))
    }

    /// What this repository does with local changes in the way; `nil` to
    /// follow the app's setting.
    static func autostash(for id: UUID, defaults: UserDefaults = .standard) -> AutostashPolicy? {
        defaults.string(forKey: key("autostash", id)).flatMap(AutostashPolicy.init(rawValue:))
    }

    static func setAutostash(_ policy: AutostashPolicy?, for id: UUID, defaults: UserDefaults = .standard) {
        defaults.set(policy?.rawValue, forKey: key("autostash", id))
    }

    /// The repository's own choice, otherwise the app's.
    static func autostashPolicy(for id: UUID) -> AutostashPolicy {
        autostash(for: id) ?? RemotePreferences.autostash
    }

    /// Whether pushing a branch of this repository takes every tag along;
    /// `nil` to follow the app's setting.
    static func pushesAllTags(for id: UUID, defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: key("pushAllTags", id)) as? Bool
    }

    static func setPushesAllTags(_ pushes: Bool?, for id: UUID, defaults: UserDefaults = .standard) {
        defaults.set(pushes, forKey: key("pushAllTags", id))
    }

    /// The repository's own choice, otherwise the app's.
    static func resolvedPushesAllTags(for id: UUID, defaults: UserDefaults = .standard) -> Bool {
        pushesAllTags(for: id, defaults: defaults) ?? PushPreferences.pushesAllTags(defaults: defaults)
    }

    /// The remote a repository fetches when nothing else chooses: the
    /// repository's chosen one, its current branch's upstream remote,
    /// `origin`, or its only remote.
    static func remoteToFetch(
        for id: UUID, remotes: [String], upstream: String?, defaults: UserDefaults = .standard
    ) -> String? {
        if let chosen = defaultRemote(for: id, defaults: defaults), remotes.contains(chosen) {
            return chosen
        }
        if let upstream, let remote = remotes.filter({ upstream.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return remote
        }
        return remotes.contains("origin") ? "origin" : remotes.count == 1 ? remotes.first : nil
    }
}

extension RepositoryModel {
    /// What this repository does with local changes that are in the way.
    var autostashPolicy: AutostashPolicy {
        RepositoryPreferences.autostashPolicy(for: id)
    }

    /// Whether pushing a branch takes every tag along.
    var pushesAllTags: Bool {
        RepositoryPreferences.resolvedPushesAllTags(for: id)
    }

    /// The remote this repository's own settings choose, if it still has it.
    var chosenDefaultRemote: String? {
        RepositoryPreferences.defaultRemote(for: id).flatMap { remoteNames.contains($0) ? $0 : nil }
    }
}
