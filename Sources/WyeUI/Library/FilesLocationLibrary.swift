import Foundation
import WyeShared

/// Why a repository was not moved into the Files location.
enum FilesLocationRefusal: LocalizedError {
    case busy(String)
    case open(String)

    var errorDescription: String? {
        switch self {
        case .busy(let name):
            "“\(name)” is busy with an operation. Move it when the operation has finished."
        case .open(let name):
            "“\(name)” is open in another window. Close it there first."
        }
    }
}

extension RepositoryLibrary {
    /// Where a new clone or repository goes when the platform does not ask
    /// for a folder: the Files location where there is one, so other apps
    /// can open it, otherwise the app's Documents.
    var newRepositoryFolder: URL {
        guard let filesStorage else { return documents }
        try? FileManager.default.createDirectory(at: filesStorage, withIntermediateDirectories: true)
        return filesStorage
    }

    /// What the clone and new repository sheets call that folder.
    var newRepositoryFolderTitle: String {
        filesStorage == nil ? "Wye’s Documents" : "Wye in the Files app"
    }

    /// Whether a repository can be moved into the Files location: one in
    /// the app's Documents, where there is such a location. Repositories
    /// added from elsewhere stay where the user keeps them.
    func canMoveToFilesLocation(_ bookmark: RepositoryBookmark) -> Bool {
        guard filesStorage != nil, case .documents = bookmark.location else { return false }
        return true
    }

    /// The listed repositories still in Documents.
    var repositoriesInDocuments: [RepositoryBookmark] {
        listedBookmarks.filter(canMoveToFilesLocation)
    }

    /// Moves a repository from Documents into the Files location. The
    /// bookmark keeps its identity, so its group, when it was last opened,
    /// its branch layout and its undo history (all kept by bookmark) stay
    /// with it; submodules and worktrees listed through it follow, being
    /// listed by their path inside it. A repository being worked on is
    /// refused, and a move that fails leaves the folder where it was.
    func moveToFilesLocation(_ bookmark: RepositoryBookmark) throws {
        guard let filesStorage, case .documents(let path) = bookmark.location else { return }
        let open = OpenRepositories.models(for: bookmark.id)
        if open.contains(where: \.isBusyForBackgroundWork) || BackgroundFetcher.shared.fetching == bookmark.id {
            throw FilesLocationRefusal.busy(bookmark.name)
        }
        // Its window would go on reading the folder where it was.
        if !open.isEmpty { throw FilesLocationRefusal.open(bookmark.name) }

        let source = documents.appending(path: path, directoryHint: .isDirectory)
        let moved = try FilesLocation.moveRepository(at: source, into: filesStorage)
        let name = moved.lastPathComponent
        for index in bookmarks.indices {
            guard case .documents(let other) = bookmarks[index].location else { continue }
            if other == path {
                bookmarks[index].location = .files(name)
            } else if other.hasPrefix(path + "/") {
                bookmarks[index].location = .files(name + other.dropFirst(path.count))
            }
        }
        sortAndSave()
        FilesLocationSignal.changed(in: [.root])
    }

    /// Moves every repository still in Documents, and says which could not
    /// be moved and why.
    func moveAllToFilesLocation() -> [(name: String, error: any Error)] {
        var failures: [(name: String, error: any Error)] = []
        for bookmark in repositoriesInDocuments {
            do {
                try moveToFilesLocation(bookmark)
            } catch {
                failures.append((bookmark.name, error))
            }
        }
        return failures
    }
}

/// Tells the Files app about Wye's own changes to working trees in the Files
/// location, such as a checkout or a pull, so the folders it shows list what
/// is there now. Calls are gathered for a moment, since one operation
/// refreshes more than once.
@MainActor
enum FilesLocationSignal {
    private static var pending: Set<FilesPath> = []
    private static var timer: Task<Void, Never>?

    /// The repository at `url` changed, if it is in the Files location.
    static func repositoryChanged(at url: URL) {
        guard let storage = FilesLocation.storageDirectory,
              let repository = FilesPath(url: url, in: storage)?.repository else { return }
        changed(in: FilesObservedFolders.folders(in: repository))
    }

    static func changed(in folders: [FilesPath]) {
        guard Platform.hasFilesLocation else { return }
        pending.formUnion(folders)
        guard timer == nil else { return }
        timer = Task {
            try? await Task.sleep(for: .milliseconds(500))
            let folders = pending
            pending = []
            timer = nil
            Platform.signalFilesLocation(folders.map(\.identifier))
        }
    }
}
