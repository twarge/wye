import Foundation
import Observation

/// What iCloud settings sync carries, and the pure logic of doing so.
enum SettingsSyncPlan {
    /// The settings that mean the same on every device. Left out on
    /// purpose: anything about one repository or account (their identifiers
    /// are each device's own), what is folded open in a window, the code
    /// font (each platform has its own default size), and where Wye shows
    /// up on the Mac.
    static let keys: [String] = [
        "fetch.prune", "fetch.backgroundInterval", "fetch.backgroundOnExpensiveNetworks",
        "newRepository.defaultBranch", "push.allTags", "tag.pushToAllRemotes", "submoduleAutoUpdate",
        "branches.staleMonths", "branches.autoArchiveMonths", "sidebar.tagLimit",
        "pullMode", "autostash", "hosting.prefersSSH",
        "commit.subjectSoftLimit", "commit.subjectHardLimit", "commit.templates",
        "diff.contextLines", "diff.ignoreWhitespace", "diff.showsInvisibles", "diff.tabWidth",
        "diff.autoCollapseFileCount",
        "history.showsGraph", "history.firstParentOnly", "history.order", "history.grouping", "history.rowSize",
        "history.showsHash", "history.showsAuthor", "history.showsDate", "history.showsChecks",
        "appearance.syntaxTheme", "workingCopy.layout", "workingCopy.sort", "repositoryListOrder",
        "authorProfiles"
    ]

    /// The repository groups, which are not in the defaults.
    static let groupsKey = "library.groups"

    /// What iCloud calls a setting: under a prefix of Wye's own.
    static func cloudKey(_ key: String) -> String { "settings." + key }

    /// The settings to send: those whose value here differs from what was
    /// last sent or received. `NSObject` values compare as property lists do.
    static func changed(local: [String: NSObject], known: [String: NSObject]) -> [String: NSObject?] {
        var changes: [String: NSObject?] = [:]
        for key in Set(local.keys).union(known.keys) where local[key] != known[key] {
            changes[key] = .some(local[key])
        }
        return changes
    }

    /// The groups as synced: their names, and which repositories are in
    /// each, by the repositories' names. A repository's identifier and
    /// place are each device's own; its folder's name mostly is not.
    struct Groups: Codable, Hashable {
        var names: [String]
        /// A repository's name to its group's.
        var membership: [String: String]
    }

    static func groups(of bookmarks: [RepositoryBookmark], in groups: [RepositoryGroup]) -> Groups {
        var membership: [String: String] = [:]
        for bookmark in bookmarks {
            guard let group = groups.first(where: { $0.id == bookmark.groupID }) else { continue }
            membership[bookmark.name] = group.name
        }
        return Groups(names: groups.map(\.name).sorted(), membership: membership)
    }
}

/// Keeps settings the same across the user's devices through iCloud's
/// key-value store, for those who turn it on. Off, nothing is sent or read.
///
/// What is here when it is turned on gives way to what iCloud already has:
/// the device set up first is the one the others follow.
///
/// Needs the iCloud key-value store entitlement; without it the store
/// keeps to this device. A build says it has the entitlement with
/// `WyeSyncsSettingsWithICloud` in its Info.plist, and only then is the
/// setting offered at all.
@MainActor
@Observable
final class SettingsSync {
    static let shared = SettingsSync()

    static let isEnabledKey = "sync.settings"
    static let infoKey = "WyeSyncsSettingsWithICloud"

    /// Whether this build can sync: it is signed for iCloud's key-value store.
    static func isAvailable(info: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        info?[infoKey] as? Bool == true
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.isEnabledKey)
            if isEnabled { begin() } else { end() }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: NSUbiquitousKeyValueStore
    @ObservationIgnored private var library: RepositoryLibrary?
    /// What each setting was when last sent or received, so that only real
    /// changes travel and a received value is not sent straight back.
    @ObservationIgnored private var known: [String: NSObject] = [:]
    @ObservationIgnored private var knownGroups: SettingsSyncPlan.Groups?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var isApplying = false

    init(defaults: UserDefaults = .standard, store: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.store = store
        isEnabled = defaults.bool(forKey: Self.isEnabledKey)
    }

    /// Starts syncing if it is turned on. Call once, as the app starts.
    func start(library: RepositoryLibrary) {
        self.library = library
        if isEnabled, Self.isAvailable() { begin() }
    }

    private func begin() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.receive(keys) }
        })
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.send() }
        })
        store.synchronize()
        // What iCloud has comes first; the rest of what is here then goes up.
        receive(SettingsSyncPlan.keys.map(SettingsSyncPlan.cloudKey) + [SettingsSyncPlan.cloudKey(SettingsSyncPlan.groupsKey)])
        send()
        followLibrary()
    }

    private func end() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        known = [:]
        knownGroups = nil
    }

    // MARK: Sending

    private func send() {
        guard isEnabled, !isApplying else { return }
        var local: [String: NSObject] = [:]
        for key in SettingsSyncPlan.keys {
            if let value = defaults.object(forKey: key) as? NSObject, defaults.persistentDomainHasValue(for: key) {
                local[key] = value
            }
        }
        for (key, value) in SettingsSyncPlan.changed(local: local, known: known) {
            if let value {
                store.set(value, forKey: SettingsSyncPlan.cloudKey(key))
            } else {
                store.removeObject(forKey: SettingsSyncPlan.cloudKey(key))
            }
        }
        known = local
        sendGroups()
    }

    private func sendGroups() {
        guard let library else { return }
        let groups = SettingsSyncPlan.groups(of: library.bookmarks, in: library.groups)
        guard groups != knownGroups, let data = try? JSONEncoder().encode(groups) else { return }
        knownGroups = groups
        store.set(data, forKey: SettingsSyncPlan.cloudKey(SettingsSyncPlan.groupsKey))
    }

    /// Sends the groups again whenever they or their repositories change.
    private func followLibrary() {
        guard isEnabled, let library else { return }
        withObservationTracking {
            _ = library.groups
            _ = library.bookmarks.map(\.groupID)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sendGroups()
                self?.followLibrary()
            }
        }
    }

    // MARK: Receiving

    private func receive(_ cloudKeys: [String]) {
        guard isEnabled else { return }
        isApplying = true
        defer { isApplying = false }
        var changed = false
        for key in SettingsSyncPlan.keys where cloudKeys.contains(SettingsSyncPlan.cloudKey(key)) {
            guard let value = store.object(forKey: SettingsSyncPlan.cloudKey(key)) as? NSObject else { continue }
            known[key] = value
            if defaults.object(forKey: key) as? NSObject != value {
                defaults.set(value, forKey: key)
                changed = true
            }
        }
        if changed {
            AppearancePreferences.shared.reloadSynced()
            DiffPreferences.shared.reloadSynced()
            HistoryPreferences.shared.reloadSynced()
            CommitPreferences.shared.reloadSynced()
            AuthorProfiles.shared.reloadSynced()
        }
        let groupsKey = SettingsSyncPlan.cloudKey(SettingsSyncPlan.groupsKey)
        if cloudKeys.contains(groupsKey), let data = store.data(forKey: groupsKey),
           let groups = try? JSONDecoder().decode(SettingsSyncPlan.Groups.self, from: data) {
            knownGroups = groups
            library?.apply(groups)
            // Applying may not reproduce them exactly: a repository that is
            // not on this device keeps its place in iCloud.
            knownGroups = library.map { SettingsSyncPlan.groups(of: $0.bookmarks, in: $0.groups) }.map { local in
                SettingsSyncPlan.Groups(names: groups.names, membership: groups.membership.merging(local.membership) { _, new in new })
            }
        }
    }
}

private extension UserDefaults {
    /// Whether the user has set this, as opposed to a registered default.
    func persistentDomainHasValue(for key: String) -> Bool {
        guard let domain = Bundle.main.bundleIdentifier.flatMap(persistentDomain(forName:)) else {
            return object(forKey: key) != nil
        }
        return domain[key] != nil
    }
}

extension RepositoryLibrary {
    /// Makes the groups another device has, and puts the repositories it
    /// names in them: those of the same name here. Groups only this device
    /// has are kept, as are repositories the other device does not mention.
    func apply(_ synced: SettingsSyncPlan.Groups) {
        var byName = Dictionary(groups.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for name in synced.names where byName[name] == nil {
            byName[name] = createGroup(named: name).id
            changed = true
        }
        for index in bookmarks.indices {
            guard let groupName = synced.membership[bookmarks[index].name], let id = byName[groupName],
                  bookmarks[index].groupID != id else { continue }
            bookmarks[index].groupID = id
            changed = true
        }
        if changed { sortAndSave() }
    }
}
