import Foundation
#if canImport(Darwin)
import notify
#endif

/// What the Finder extension draws on a file or folder.
public enum FinderBadge: String, Codable, Sendable, CaseIterable {
    case modified
    case staged
    case untracked
    case conflicted

    /// Which of two badges a folder shows when it holds both: the one
    /// that most wants attention.
    var rank: Int {
        switch self {
        case .conflicted: 3
        case .modified: 2
        case .untracked: 1
        case .staged: 0
        }
    }
}

/// One repository as the Finder extension knows it: where it is, and the
/// badge of each changed path in it.
public struct FinderRepositoryStatus: Codable, Hashable, Sendable {
    /// The repository list's bookmark id, for `wye://open`.
    public var id: UUID
    public var name: String
    /// The working tree's folder, as an absolute path without a trailing slash.
    public var root: String
    public var branch: String?
    /// Changed files by their path from the root.
    public var badges: [String: FinderBadge]

    public init(id: UUID, name: String, root: String, branch: String?, badges: [String: FinderBadge]) {
        self.id = id
        self.name = name
        self.root = Self.normalized(root)
        self.branch = branch
        self.badges = badges
    }

    static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The most changed files written for one repository: beyond this the
    /// file is large and the badges are noise anyway.
    public static let limit = 5000
}

/// Every badge the extension draws, by absolute path: the changed files,
/// and the folders above them up to and including each repository's root.
public struct FinderBadgeIndex: Sendable {
    public private(set) var badges: [String: FinderBadge] = [:]
    public private(set) var repositories: [FinderRepositoryStatus] = []

    public init(_ repositories: [FinderRepositoryStatus]) {
        // Longest root first, so a repository inside another is found first.
        self.repositories = repositories.sorted { $0.root.count > $1.root.count }
        for repository in repositories {
            for (path, badge) in repository.badges {
                var components = path.split(separator: "/").map(String.init)
                mark(repository.root + "/" + components.joined(separator: "/"), badge)
                // Each folder above the file, then the repository's own.
                while !components.isEmpty {
                    components.removeLast()
                    let folder = components.isEmpty ? repository.root : repository.root + "/" + components.joined(separator: "/")
                    mark(folder, badge == .staged || badge == .untracked ? .modified : badge)
                }
            }
        }
    }

    private mutating func mark(_ path: String, _ badge: FinderBadge) {
        if let existing = badges[path], existing.rank >= badge.rank { return }
        badges[path] = badge
    }

    public func badge(forPath path: String) -> FinderBadge? {
        badges[FinderRepositoryStatus.normalized(path)]
    }

    /// The repository a path is in or is the root of.
    public func repository(containing path: String) -> FinderRepositoryStatus? {
        let path = FinderRepositoryStatus.normalized(path)
        return repositories.first { path == $0.root || path.hasPrefix($0.root + "/") }
    }
}

/// One file per repository in the shared container, written by the app and
/// read by the Finder extension, which is told of each change by a Darwin
/// notification.
public enum FinderStatusStore {
    public static let changeNotification = "com.twarge.app.wye.finder-status"

    static var directory: URL {
        SharedContainer.directory.appending(path: "Finder", directoryHint: .isDirectory)
    }

    public static func save(_ status: FinderRepositoryStatus) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(status).write(to: file(for: status.id), options: .atomic)
            postChange()
        } catch {
            // Finder showing a stale badge is not worth an alert.
        }
    }

    /// Removes the files of repositories no longer listed.
    public static func retain(_ ids: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = false
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
            removed = true
        }
        if removed { postChange() }
    }

    public static func loadAll() -> [FinderRepositoryStatus] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(FinderRepositoryStatus.self, from: $0) }
        }
    }

    private static func file(for id: UUID) -> URL {
        directory.appending(path: id.uuidString + ".json")
    }

    private static func postChange() {
        // Not for a folder a test pointed the container at.
        guard SharedContainer.directoryOverride == nil else { return }
        #if canImport(Darwin)
        notify_post(changeNotification)
        #endif
    }
}
