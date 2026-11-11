import Foundation
import GitKit

/// A folder the user registered: every repository in it is listed, and the
/// list follows as repositories arrive and leave.
struct WatchedFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Bookmark data carrying the permission to open the folder again.
    var bookmark: Data
}

/// A watched folder in use: its location, the permission held open on it,
/// and the watch for changes to what it contains.
@MainActor
final class OpenWatchedFolder {
    let url: URL
    private let isScoped: Bool
    private var source: (any DispatchSourceFileSystemObject)?

    init(url: URL, changed: @escaping @MainActor () -> Void) {
        self.url = url
        isScoped = url.startAccessingSecurityScopedResource()

        // Fires when something is added to, removed from or renamed in the
        // folder itself, which is what a repository coming or going is.
        let descriptor = Darwin.open(url.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .link], queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { changed() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        self.source = source
    }

    func close() {
        source?.cancel()
        source = nil
        if isScoped {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

extension RepositoryLibrary {
    /// Starts listing the repositories in a folder, now and as they change.
    @discardableResult
    func watch(_ url: URL) throws -> WatchedFolder {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        let url = url.standardizedFileURL
        if let existing = folders.first(where: { openFolders[$0.id]?.url.standardizedFileURL == url }) {
            return existing
        }
        let folder = WatchedFolder(name: url.lastPathComponent, bookmark: try url.repositoryBookmark())
        folders.append(folder)
        open(folder)
        syncWatchedFolders()
        sortAndSave()
        return folder
    }

    /// Stops watching a folder and forgets the repositories listed through
    /// it. Their files are left alone.
    func stopWatching(_ folder: WatchedFolder) {
        openFolders.removeValue(forKey: folder.id)?.close()
        folders.removeAll { $0.id == folder.id }
        bookmarks.removeAll { $0.watchedFolder == folder.id }
        sortAndSave()
    }

    /// Where a watched folder is, when it can be reached.
    func url(of folder: WatchedFolder) -> URL? {
        openFolders[folder.id]?.url
    }

    /// Where a watched folder is, for display.
    func path(of folder: WatchedFolder) -> String? {
        openFolders[folder.id].map { open in
            let path = open.url.path(percentEncoded: false)
            let home = URL.homeDirectory.path(percentEncoded: false)
            return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
        }
    }

    /// Opens every saved watched folder and brings the list up to date.
    func openWatchedFolders() {
        for folder in folders {
            open(folder)
        }
        syncWatchedFolders()
    }

    /// Makes the list match what is in the watched folders: adds the
    /// repositories that have appeared and drops the ones that have gone.
    /// Repositories added any other way are never touched.
    func syncWatchedFolders() {
        var changed = false
        for folder in folders {
            guard let root = openFolders[folder.id]?.url else { continue }
            // A folder that cannot be read right now (an unplugged disk) says
            // nothing about what is in it, so its repositories stay listed.
            guard let present = repositories(in: root) else { continue }

            let listed = bookmarks.filter { $0.watchedFolder == folder.id }
            let gone = listed.filter { bookmark in
                guard case .watched(_, let path) = bookmark.location else { return false }
                return !present.contains(path)
            }
            if !gone.isEmpty {
                let ids = Set(gone.map(\.id))
                bookmarks.removeAll { ids.contains($0.id) }
                changed = true
            }

            let known = Set(bookmarks.compactMap { try? resolve($0).url.standardizedFileURL })
            for path in present {
                let url = root.appending(path: path, directoryHint: .isDirectory).standardizedFileURL
                guard !known.contains(url) else { continue }
                bookmarks.append(RepositoryBookmark(
                    name: url.lastPathComponent, location: .watched(folder: folder.id, path: path)
                ))
                changed = true
            }
        }
        if changed {
            sortAndSave()
        }
    }

    private func open(_ folder: WatchedFolder) {
        guard openFolders[folder.id] == nil else { return }
        var isStale = false
        guard let url = try? URL(resolvingRepositoryBookmark: folder.bookmark, isStale: &isStale) else { return }
        openFolders[folder.id] = OpenWatchedFolder(url: url) { [weak self] in
            self?.syncWatchedFolders()
        }
        if isStale, let fresh = try? url.repositoryBookmark(),
           let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index].bookmark = fresh
        }
    }

    /// The repositories directly in a folder, and one level further down in
    /// the folders that are not repositories themselves, as paths from the
    /// folder. `nil` when the folder cannot be read.
    private func repositories(in root: URL) -> Set<String>? {
        guard let children = try? subfolders(of: root) else { return nil }
        var found: Set<String> = []
        for child in children {
            if Repository.exists(at: child) {
                found.insert(child.lastPathComponent)
            } else {
                for grandchild in (try? subfolders(of: child)) ?? [] where Repository.exists(at: grandchild) {
                    found.insert(child.lastPathComponent + "/" + grandchild.lastPathComponent)
                }
            }
        }
        return found
    }

    private func subfolders(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}

extension RepositoryBookmark {
    /// The watched folder this repository is listed through, if any.
    var watchedFolder: UUID? {
        if case .watched(let folder, _) = location { folder } else { nil }
    }
}
