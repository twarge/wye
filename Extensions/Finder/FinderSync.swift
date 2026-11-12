import Cocoa
import FinderSync
import WyeShared
import notify

/// Wye in the Finder: a badge on each changed file of a listed repository
/// and on the folders above it, and Open in Wye in the contextual menu and
/// the toolbar.
///
/// The extension has no git and reads no repository. The app writes what
/// each repository's files are to its group container (`FinderStatusStore`)
/// and posts a notification; this draws what the files say.
final class FinderSync: FIFinderSync {
    private var index = FinderBadgeIndex([])
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    override init() {
        super.init()
        let controller = FIFinderSyncController.default()
        for badge in FinderBadge.allCases {
            let (symbol, label) = Self.appearance(of: badge)
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
                controller.setBadgeImage(image, label: label, forBadgeIdentifier: badge.rawValue)
            }
        }
        notify_register_dispatch(FinderStatusStore.changeNotification, &token, .main) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    deinit {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
    }

    private static func appearance(of badge: FinderBadge) -> (symbol: String, label: String) {
        switch badge {
        case .modified: ("pencil.circle.fill", "Modified")
        case .staged: ("plus.circle.fill", "Staged")
        case .untracked: ("questionmark.circle.fill", "Untracked")
        case .conflicted: ("exclamationmark.triangle.fill", "Conflicted")
        }
    }

    /// Reads the status files again and has the Finder redraw what changed.
    private func reload() {
        let old = index
        index = FinderBadgeIndex(FinderStatusStore.loadAll())
        let controller = FIFinderSyncController.default()
        controller.directoryURLs = Set(index.repositories.map { URL(filePath: $0.root, directoryHint: .isDirectory) })
        // Only what changed: asking for every badge again makes Finder flicker.
        let paths = Set(old.badges.keys).union(index.badges.keys)
        for path in paths where old.badges[path] != index.badges[path] {
            controller.setBadgeIdentifier(index.badges[path]?.rawValue ?? "", for: URL(filePath: path))
        }
    }

    // MARK: Badges

    override func requestBadgeIdentifier(for url: URL) {
        let badge = index.badge(forPath: url.path(percentEncoded: false))
        FIFinderSyncController.default().setBadgeIdentifier(badge?.rawValue ?? "", for: url)
    }

    // MARK: Menus

    override var toolbarItemName: String { "Wye" }
    override var toolbarItemToolTip: String { "Open this folder’s repository in Wye" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Wye") ?? NSImage()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard let repository = repository(for: menuKind) else { return nil }
        let menu = NSMenu(title: "Wye")
        let title = repository.branch.map { "Open “\(repository.name)” in Wye (\($0))" } ?? "Open “\(repository.name)” in Wye"
        let item = NSMenuItem(title: title, action: #selector(openInWye(_:)), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    /// The repository of what the menu is for: the selection, or the folder
    /// the window shows.
    private func repository(for menuKind: FIMenuKind? = nil) -> FinderRepositoryStatus? {
        let controller = FIFinderSyncController.default()
        let urls = (controller.selectedItemURLs() ?? []) + [controller.targetedURL()].compactMap(\.self)
        return urls.lazy.compactMap { self.index.repository(containing: $0.path(percentEncoded: false)) }.first
    }

    @objc private func openInWye(_ sender: Any?) {
        guard let repository = repository() else { return }
        NSWorkspace.shared.open(WyeLink.openRepository(repository.id).url)
    }
}
