import Foundation
import GitKit
import Observation

/// A repository the app knows about.
struct RepositoryBookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var location: Location
    /// The group the repository list shows it in; `nil` for none. Added
    /// later than the rest, so missing from older saved lists.
    var groupID: UUID?
    /// When it was last opened, for sorting the list.
    var lastOpened: Date?

    enum Location: Codable, Hashable {
        /// A folder in the app's Documents, by its path from there. The
        /// container's own path changes between installs, so it is not stored.
        case documents(String)
        /// A folder elsewhere that the user picked, as bookmark data that
        /// carries the permission to open it again.
        case external(Data)
        /// A folder inside a watched folder, by its path from there. The
        /// watched folder's permission covers it.
        case watched(folder: UUID, path: String)
    }
}

/// Access to a repository's folder, held for as long as the repository is open.
final class RepositoryAccess {
    let url: URL
    private let isScoped: Bool

    init(url: URL, scoped: Bool) {
        self.url = url
        isScoped = scoped && url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isScoped {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

enum LibraryError: LocalizedError {
    case notARepository(URL)

    var errorDescription: String? {
        switch self {
        case .notARepository(let url):
            "“\(url.lastPathComponent)” is not a git repository. Choose the folder that contains its .git folder."
        }
    }
}

/// The repositories the app knows about, kept between launches.
@MainActor
@Observable
final class RepositoryLibrary {
    var bookmarks: [RepositoryBookmark] = []
    /// A repository for the next new window to open, set just before one is
    /// asked for. The window clears it.
    var openInNextWindow: RepositoryBookmark.ID?
    /// The repository list's groups, by name.
    private(set) var groups: [RepositoryGroup] = []
    /// Folders whose repositories are listed for as long as they are there.
    var folders: [WatchedFolder] = []
    /// Each watched folder as resolved and opened for this run.
    var openFolders: [UUID: OpenWatchedFolder] = [:]

    private let storage: URL
    private let documents: URL

    init(
        storage: URL = .applicationSupportDirectory.appending(path: "Twig/Repositories.json"),
        documents: URL = .documentsDirectory
    ) {
        self.storage = storage
        self.documents = documents.standardizedFileURL
        if let data = try? Data(contentsOf: storage), let saved = try? LibraryFile.decode(data) {
            bookmarks = saved.repositories
            groups = saved.groups
            folders = saved.folders
        }
        discoverDocuments()
        openWatchedFolders()
    }

    /// Adds the repository in a folder, or returns the bookmark it already has.
    @discardableResult
    func add(_ url: URL) throws -> RepositoryBookmark {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        let url = url.standardizedFileURL
        guard Repository.exists(at: url) else { throw LibraryError.notARepository(url) }
        if let existing = bookmarks.first(where: { (try? resolve($0).url.standardizedFileURL) == url }) {
            return existing
        }

        let location: RepositoryBookmark.Location = if let path = pathInDocuments(of: url) {
            .documents(path)
        } else {
            .external(try url.repositoryBookmark())
        }
        let bookmark = RepositoryBookmark(name: url.lastPathComponent, location: location)
        bookmarks.append(bookmark)
        sortAndSave()
        return bookmark
    }

    /// Forgets a repository. Its files are left alone.
    func remove(_ bookmark: RepositoryBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        sortAndSave()
    }

    /// Notes that a repository was opened, for sorting by when.
    func recordOpened(_ bookmark: RepositoryBookmark) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index].lastOpened = .now
        sortAndSave()
    }

    // MARK: Groups

    @discardableResult
    func createGroup(named name: String) -> RepositoryGroup {
        let group = RepositoryGroup(name: name)
        groups.append(group)
        sortAndSave()
        return group
    }

    func renameGroup(_ group: RepositoryGroup, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = name
        sortAndSave()
    }

    /// Deletes a group. Its repositories stay, outside any group.
    func deleteGroup(_ group: RepositoryGroup) {
        groups.removeAll { $0.id == group.id }
        for index in bookmarks.indices where bookmarks[index].groupID == group.id {
            bookmarks[index].groupID = nil
        }
        sortAndSave()
    }

    /// Puts repositories in a group, or in none when `group` is `nil`.
    func move(_ ids: [UUID], to group: RepositoryGroup.ID?) {
        let ids = Set(ids)
        for index in bookmarks.indices where ids.contains(bookmarks[index].id) {
            bookmarks[index].groupID = group
        }
        sortAndSave()
    }

    /// The group a repository is shown in; `nil` also when its group is gone.
    func group(of bookmark: RepositoryBookmark) -> RepositoryGroup? {
        groups.first { $0.id == bookmark.groupID }
    }

    /// Opens access to a repository's folder.
    func access(to bookmark: RepositoryBookmark) throws -> RepositoryAccess {
        let resolved = try resolve(bookmark)
        if let fresh = resolved.refreshedLocation, let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index].location = fresh
            sortAndSave()
        }
        return RepositoryAccess(url: resolved.url, scoped: resolved.isScoped)
    }

    /// Where a repository is, for display. `nil` once the folder is gone.
    func path(of bookmark: RepositoryBookmark) -> String? {
        (try? resolve(bookmark).url.path(percentEncoded: false)).map { path in
            let home = URL.homeDirectory.path(percentEncoded: false)
            return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
        }
    }

    func resolve(
        _ bookmark: RepositoryBookmark
    ) throws -> (url: URL, isScoped: Bool, refreshedLocation: RepositoryBookmark.Location?) {
        switch bookmark.location {
        case .documents(let path):
            return (documents.appending(path: path, directoryHint: .isDirectory), false, nil)
        case .external(let data):
            var isStale = false
            let url = try URL(resolvingRepositoryBookmark: data, isStale: &isStale)
            // A stale bookmark still resolves, but should be made anew.
            let fresh = isStale ? (try? url.repositoryBookmark()).map(RepositoryBookmark.Location.external) : nil
            return (url, true, fresh)
        case .watched(let folder, let path):
            guard let open = openFolders[folder] else { throw CocoaError(.fileNoSuchFile) }
            return (open.url.appending(path: path, directoryHint: .isDirectory), false, nil)
        }
    }

    /// Lists the repositories in the app's Documents, where clones are kept
    /// and where the Files app can put one.
    private func discoverDocuments() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        let known = Set(bookmarks.map(\.location))
        var changed = false
        for folder in folders where Repository.exists(at: folder) {
            guard let path = pathInDocuments(of: folder), !known.contains(.documents(path)) else { continue }
            bookmarks.append(RepositoryBookmark(name: folder.lastPathComponent, location: .documents(path)))
            changed = true
        }
        if changed {
            sortAndSave()
        }
    }

    private func pathInDocuments(of url: URL) -> String? {
        let base = documents.path(percentEncoded: false)
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(base), path.count > base.count else { return nil }
        return path.dropFirst(base.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func sortAndSave() {
        bookmarks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do {
            try FileManager.default.createDirectory(
                at: storage.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try LibraryFile(repositories: bookmarks, groups: groups, folders: folders).encoded().write(to: storage, options: .atomic)
        } catch {
            // The list is still right for this run; it is only not saved.
        }
    }
}
