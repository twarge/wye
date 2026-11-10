import Foundation

/// Where a repository keeps its files, as the watcher needs them: real
/// paths, with symbolic links resolved, because that is how the file
/// system reports changes.
struct RepositoryLocations: Equatable, Sendable {
    /// The working tree; `nil` for a bare repository.
    var workTree: String?
    /// The git directory: `HEAD`, the index, and the state of a merge or rebase.
    var gitDirectory: String
    /// Where refs, `packed-refs` and `config` live. The git directory itself,
    /// except in a linked worktree.
    var commonDirectory: String

    /// The folders to watch: the working tree, which holds the git directory
    /// in the usual layout, and whichever git folders lie outside it.
    var roots: [String] {
        var roots: [String] = []
        for path in [workTree, gitDirectory, commonDirectory].compactMap(\.self)
        where !roots.contains(where: { path.isInside($0) }) {
            roots.removeAll { $0.isInside(path) }
            roots.append(path)
        }
        return roots
    }

    /// Finds the folders of the repository opened from `url`. A `.git` file,
    /// as a linked worktree or submodule has, names the real git directory.
    init(repositoryURL url: URL, isBare: Bool) {
        let top = Self.realPath(url.path(percentEncoded: false))
        if isBare {
            workTree = nil
            gitDirectory = top
        } else {
            workTree = top
            let dotGit = top + "/.git"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory), !isDirectory.boolValue,
               let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
               let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") {
                let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                gitDirectory = Self.realPath(target.hasPrefix("/") ? target : top + "/" + target)
            } else {
                gitDirectory = Self.realPath(dotGit)
            }
        }
        if let text = try? String(contentsOfFile: gitDirectory + "/commondir", encoding: .utf8) {
            let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
            commonDirectory = Self.realPath(target.hasPrefix("/") ? target : gitDirectory + "/" + target)
        } else {
            commonDirectory = gitDirectory
        }
    }

    init(workTree: String?, gitDirectory: String, commonDirectory: String? = nil) {
        self.workTree = workTree
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory ?? gitDirectory
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return URL(filePath: path).standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlash
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// A change on disk that may change what the repository window shows.
enum RepositoryChange: Hashable, Sendable {
    /// `HEAD`, the index, a ref, the config, or a merge or rebase starting or ending.
    case gitDirectory
    /// A file in the working tree, by its path from the top of the tree.
    case workingTree(String)
    /// The file system lost track of what changed; read everything again.
    case rescan
}

/// Sorts the paths the file system reports into changes that matter and
/// noise. Git rewrites objects, logs and lock files constantly; those never
/// change what Twig shows by themselves, because whatever matters about
/// them lands in a ref or the index too.
struct RepositoryChangeFilter: Sendable {
    let locations: RepositoryLocations

    /// Files in the git directory whose change matters.
    private static let gitFiles: Set<String> = [
        "HEAD", "index", "packed-refs", "config", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
        "REBASE_HEAD", "BISECT_LOG", "info/exclude"
    ]
    /// Folders in the git directory where any change matters.
    private static let gitFolders = ["refs", "rebase-merge", "rebase-apply", "sequencer", "worktrees"]

    func classify(_ path: String, isRescan: Bool = false) -> RepositoryChange? {
        if isRescan { return .rescan }
        let path = path.trimmingTrailingSlash
        for directory in [locations.gitDirectory, locations.commonDirectory] {
            if let inside = path.relative(to: directory) {
                return Self.isRelevantInGitDirectory(inside) ? .gitDirectory : nil
            }
        }
        guard let workTree = locations.workTree, let inside = path.relative(to: workTree), !inside.isEmpty else {
            return nil
        }
        // Another repository nested in the tree, or a submodule's own git
        // folder, churns like ours does; its state shows through its files.
        if inside.split(separator: "/").contains(".git") { return nil }
        return .workingTree(inside)
    }

    private static func isRelevantInGitDirectory(_ path: String) -> Bool {
        // A lock is written, then renamed over the real file, which reports
        // its own change.
        guard !path.isEmpty, !path.hasSuffix(".lock") else { return false }
        if gitFiles.contains(path) { return true }
        let components = path.split(separator: "/")
        guard let first = components.first.map(String.init) else { return false }
        if first == "worktrees" {
            // Another worktree's index and logs are its own business.
            return components.count < 3 || !["index", "logs"].contains(String(components[2]))
        }
        if first == "modules" {
            // A submodule's checkout moving changes its entry in our status.
            return components.last == "HEAD"
        }
        return gitFolders.contains(first)
    }
}

/// Decides when a run of changes on disk becomes one refresh.
///
/// A change waits for a quiet moment, so a burst of writes (a checkout, a
/// build, another git command) is read once at its end; but never longer
/// than `maximumDelay`, so a stream of writes still shows. A refresh that
/// began after a change was stamped has read it, so that change is dropped:
/// this is what keeps Twig's own operations, which end with a refresh, from
/// causing a second one.
struct RefreshCoalescer {
    typealias Instant = ContinuousClock.Instant

    var quietPeriod: Duration = .milliseconds(250)
    var maximumDelay: Duration = .seconds(1)

    private(set) var firstChange: Instant?
    private(set) var lastChange: Instant?
    /// The newest stamp among the pending changes.
    private(set) var newestStamp: UInt64 = 0
    /// Changes stamped up to here have been read by a refresh.
    private(set) var coveredStamp: UInt64 = 0

    var hasPending: Bool { firstChange != nil }

    /// Notes a change. Returns `false` if a refresh already covers it.
    @discardableResult
    mutating func record(stamp: UInt64, at now: Instant) -> Bool {
        guard stamp > coveredStamp else { return false }
        newestStamp = max(newestStamp, stamp)
        if firstChange == nil { firstChange = now }
        lastChange = now
        return true
    }

    /// A refresh began: it reads everything stamped up to `stamp`.
    mutating func refreshBegan(covering stamp: UInt64) {
        coveredStamp = max(coveredStamp, stamp)
        if hasPending, newestStamp <= coveredStamp {
            clear()
        }
    }

    /// When the pending changes are due a refresh, if any are pending.
    var deadline: Instant? {
        guard let firstChange, let lastChange else { return nil }
        return min(lastChange + quietPeriod, firstChange + maximumDelay)
    }

    /// Whether to refresh now. A due refresh waits while Twig is busy with a
    /// refresh or an operation of its own, which will read the changes anyway.
    func isDue(at now: Instant, isBusy: Bool) -> Bool {
        guard let deadline, !isBusy else { return false }
        return now >= deadline
    }

    mutating func clear() {
        firstChange = nil
        lastChange = nil
        newestStamp = 0
    }
}

extension String {
    /// The rest of the path below `directory`: empty for the directory
    /// itself, `nil` for a path outside it.
    func relative(to directory: String) -> String? {
        if self == directory { return "" }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    func isInside(_ directory: String) -> Bool {
        relative(to: directory) != nil
    }

    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
