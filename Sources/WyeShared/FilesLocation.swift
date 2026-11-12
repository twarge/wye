import Foundation
import notify
#if os(iOS)
import FileProvider
#endif

/// Wye's own location in the Files app on iOS, where each repository in the
/// provider's storage shows as a folder that other apps can open and edit in
/// place. The app and the File Provider extension both read this, so they
/// agree on where the storage is, how an item is named and what is hidden.
///
/// The working trees are real folders in the storage: libgit2 in the app
/// reads and writes them directly, and the extension only describes them to
/// the system. There is no second copy.
public enum FilesLocation {
    /// Overrides the storage folder; tests point it at a temporary one.
    nonisolated(unsafe) public static var storageOverride: URL?

    /// The folder whose repositories the Files location shows; `nil` where
    /// there is no such location (macOS, where repositories are wherever the
    /// user keeps them).
    public static var storageDirectory: URL? {
        if let storageOverride { return storageOverride }
        #if os(iOS)
        // In the app group's container, named by the extension's
        // NSExtensionFileProviderDocumentGroup.
        return NSFileProviderManager.default.documentStorageURL
        #else
        return nil
        #endif
    }

    /// The Darwin notification the extension posts after another app wrote
    /// to, created, renamed or deleted something through the location, so
    /// an open repository refreshes without waiting to come to the front.
    /// It keeps the app's original identifier, as the app group does.
    public static let changeNotification = "com.twarge.app.wye.files.changed"

    /// Tells the app that something in the location changed.
    public static func postChange() {
        notify_post(changeNotification)
    }

    /// Whether a name is git's own and kept out of the location: the `.git`
    /// folder of a repository, or the `.git` file of a linked worktree or a
    /// submodule. Names that only begin with `.git`, such as `.gitignore`
    /// or `.github`, are ordinary files. Compared ignoring case, as git
    /// itself protects `.GIT` on file systems that ignore case.
    public static func isHidden(_ name: String) -> Bool {
        name.compare(".git", options: .caseInsensitive) == .orderedSame
    }

    /// Whether `name` is listed in the folder at `parent`. The top level
    /// lists only the repositories' folders; inside a repository everything
    /// but git's own data is listed, dotfiles included.
    public static func isListed(_ name: String, isDirectory: Bool, in parent: FilesPath) -> Bool {
        if parent.isRoot {
            return isDirectory && !name.hasPrefix(".")
        }
        return !isHidden(name)
    }

    /// Whether a new or changed name may be used: one path component that
    /// is not git's own.
    public static func isAllowedName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && !isHidden(name)
    }
}

/// An item in the Files location, as its path below the storage folder.
/// The path is also the item's identifier, so the app and the extension
/// name an item the same way without keeping a table between them. An item
/// renamed or moved through the location gets the identifier of its new
/// path, and the extension reports the old one as gone.
public struct FilesPath: Hashable, Sendable, CustomStringConvertible {
    /// The path's components; none for the location's top level.
    public let components: [String]

    public static let root = FilesPath(checked: [])

    private init(checked components: [String]) {
        self.components = components
    }

    /// A path from its components, refusing anything that could reach
    /// outside the storage or into git's own data.
    public init?(components: [String]) {
        guard components.allSatisfy(FilesLocation.isAllowedName) else { return nil }
        self.components = components
    }

    /// A path from an identifier, as `identifier` writes it.
    public init?(identifier: String) {
        guard !identifier.isEmpty else { return nil }
        self.init(components: identifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    }

    /// The path of a file or folder below `storage`; `nil` for anything
    /// outside it or inside git's own data.
    public init?(url: URL, in storage: URL) {
        let base = Self.comparable(storage)
        // The item itself may be a link in a working tree: name the link,
        // not what it points to.
        let url = url.standardizedFileURL
        let path = Self.comparable(url) == base ? base
            : Self.comparable(url.deletingLastPathComponent()) + "/" + url.lastPathComponent
        if path == base {
            self = .root
            return
        }
        guard path.hasPrefix(base + "/") else { return nil }
        self.init(identifier: String(path.dropFirst(base.count + 1)))
    }

    /// The identifier this item has in the location: its path. The top
    /// level has the system's own identifier instead, so `nil` here.
    public var identifier: String? {
        isRoot ? nil : components.joined(separator: "/")
    }

    public var description: String { identifier ?? "/" }

    public var isRoot: Bool { components.isEmpty }

    /// Whether this is a repository's own folder, at the top level. Those
    /// are not renamed, moved or deleted from the Files app: Wye lists them
    /// by where they are, and removes them itself.
    public var isRepositoryRoot: Bool { components.count == 1 }

    /// The repository's folder this item is in, or is.
    public var repository: FilesPath? {
        components.first.map { FilesPath(checked: [$0]) }
    }

    public var name: String { components.last ?? "" }

    public var parent: FilesPath? {
        isRoot ? nil : FilesPath(checked: Array(components.dropLast()))
    }

    public func appending(_ name: String) -> FilesPath? {
        FilesPath(components: components + [name])
    }

    /// Whether this is `other` or inside it.
    public func isWithin(_ other: FilesPath) -> Bool {
        components.starts(with: other.components)
    }

    public func url(in storage: URL) -> URL {
        components.reduce(storage) { url, name in url.appending(path: name) }
    }

    /// A path with links in it resolved and no slash at the end, so
    /// `/var` and `/private/var` compare equal.
    private static func comparable(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// What may be done to an item through the Files app. Kept apart from the
/// File Provider's own capabilities so it can be tested without it.
public struct FilesPermissions: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let read = FilesPermissions(rawValue: 1 << 0)
    /// Change a file's contents, or add items to a folder.
    public static let write = FilesPermissions(rawValue: 1 << 1)
    public static let rename = FilesPermissions(rawValue: 1 << 2)
    public static let move = FilesPermissions(rawValue: 1 << 3)
    public static let delete = FilesPermissions(rawValue: 1 << 4)

    /// What the location allows on the item at `path`. The top level only
    /// lists the repositories, which are made in Wye; a repository's own
    /// folder takes new items but is not renamed, moved or deleted.
    public static func of(_ path: FilesPath) -> FilesPermissions {
        if path.isRoot { return .read }
        if path.isRepositoryRoot { return [.read, .write] }
        return [.read, .write, .rename, .move, .delete]
    }

    /// Whether the item at `source` may go into the folder at `parent`
    /// under `name`: within the location, into a repository, and not into
    /// itself.
    public static func canMove(_ source: FilesPath, into parent: FilesPath, as name: String) -> Bool {
        guard of(source).contains(.move), of(parent).contains(.write), FilesLocation.isAllowedName(name) else {
            return false
        }
        return !parent.isWithin(source)
    }
}

/// The folders the Files app has open in the location, as the extension
/// last saw them, so the app knows which ones to tell about its own changes
/// (a checkout, a pull). The extension writes it; the app only reads it.
public enum FilesObservedFolders {
    static let fileName = "FilesObservedFolders.json"

    /// Folders not looked at for this long are no longer signalled.
    static let lifetime: TimeInterval = 3600
    /// Enough for every window of an iPad; older entries go first.
    static let limit = 64

    nonisolated(unsafe) public static var fileURLOverride: URL?

    static var fileURL: URL {
        fileURLOverride ?? SharedContainer.directory.appending(path: fileName)
    }

    private static let lock = NSLock()

    /// Notes that the Files app is looking at a folder.
    public static func note(_ path: FilesPath, now: Date = .now) {
        update { $0[path.identifier ?? ""] = now }
    }

    /// Notes that it stopped.
    public static func forget(_ path: FilesPath) {
        update { $0[path.identifier ?? ""] = nil }
    }

    /// The folders being looked at inside `repository`'s folder, with the
    /// repository's folder and the top level always among them.
    public static func folders(in repository: FilesPath, now: Date = .now) -> [FilesPath] {
        var result: Set<FilesPath> = [.root, repository]
        for (identifier, seen) in load() where now.timeIntervalSince(seen) < lifetime {
            guard let path = identifier.isEmpty ? .root : FilesPath(identifier: identifier),
                  path.isWithin(repository) else { continue }
            result.insert(path)
        }
        return result.sorted { $0.components.count < $1.components.count }
    }

    private static func load() -> [String: Date] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    private static func update(_ change: (inout [String: Date]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var folders = load()
        change(&folders)
        if folders.count > limit {
            for (identifier, _) in folders.sorted(by: { $0.value < $1.value }).prefix(folders.count - limit) {
                folders[identifier] = nil
            }
        }
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Why a repository could not go into the Files location.
public enum FilesLocationMoveError: LocalizedError, Equatable {
    case nameTaken(String)
    case linkedWorktree(String)
    case hasWorktrees(String)
    case notARepository(String)

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name):
            "A repository named “\(name)” is already in the Files location. Rename one of them first."
        case .linkedWorktree(let name):
            "“\(name)” is a linked worktree, whose repository records where it is. Move the repository instead, or keep it where it is."
        case .hasWorktrees(let name):
            "“\(name)” has linked worktrees, which record where the repository is and would lose it. Remove the worktrees first."
        case .notARepository(let name):
            "“\(name)” is not a git repository."
        }
    }
}

extension FilesLocation {
    /// Moves the repository folder at `folder` into `storage`, keeping its
    /// name, and returns where it now is. The move is one rename on the same
    /// volume, so a failure leaves the folder where it was. Refuses a linked
    /// worktree, or a repository with linked worktrees: each records the
    /// other's folder by its full path, which the move would break.
    public static func moveRepository(at folder: URL, into storage: URL) throws -> URL {
        let manager = FileManager.default
        let name = folder.lastPathComponent
        let git = folder.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: git.path(percentEncoded: false), isDirectory: &isDirectory) else {
            throw FilesLocationMoveError.notARepository(name)
        }
        guard isDirectory.boolValue else { throw FilesLocationMoveError.linkedWorktree(name) }
        let worktrees = (try? manager.contentsOfDirectory(atPath: git.appending(path: "worktrees").path(percentEncoded: false))) ?? []
        guard worktrees.isEmpty else { throw FilesLocationMoveError.hasWorktrees(name) }
        let destination = storage.appending(path: name, directoryHint: .isDirectory)
        guard !manager.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw FilesLocationMoveError.nameTaken(name)
        }
        try manager.createDirectory(at: storage, withIntermediateDirectories: true)
        try manager.moveItem(at: folder, to: destination)
        return destination
    }
}
