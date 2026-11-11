import SwiftUI

/// File ▸ Open Recent: the repositories opened last, newest first, from the
/// same record the repository list sorts by.
struct OpenRecentMenu: View {
    var library: RepositoryLibrary
    var window: WindowActions?

    @FocusedValue(RepositoryModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Open Recent") {
            let recent = library.recentBookmarks()
            ForEach(recent) { bookmark in
                Button(bookmark.name) { open(bookmark) }
            }
            if !recent.isEmpty {
                Divider()
            }
            Button("Clear Menu") { library.clearRecent() }
                .disabled(recent.isEmpty)
        }
    }

    /// In the front window when it shows the list, otherwise in a new one,
    /// as a document app opens a recent document.
    private func open(_ bookmark: RepositoryBookmark) {
        if let window, model == nil || model?.id == bookmark.id || !Platform.hasWindowTabs {
            if model?.id != bookmark.id { window.open(bookmark) }
        } else {
            library.openInNextWindow = bookmark.id
            openWindow(id: TwigScene.windowID)
        }
    }
}

extension RepositoryLibrary {
    /// How many repositories Open Recent lists.
    static let recentLimit = 10

    /// The listed repositories that have been opened, most recent first.
    func recentBookmarks(limit: Int = recentLimit) -> [RepositoryBookmark] {
        let listed = Set(listedBookmarks.map(\.id))
        return bookmarks
            .filter { $0.lastOpened != nil && listed.contains($0.id) }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            .prefix(limit)
            .map(\.self)
    }

    /// Forgets when each repository was opened. The list's Last Opened
    /// order then falls back to names, as it would for a new list.
    func clearRecent() {
        for index in bookmarks.indices {
            bookmarks[index].lastOpened = nil
        }
        sortAndSave()
    }
}
