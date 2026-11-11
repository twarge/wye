import Foundation
import GitKit

/// Why a submodule or worktree could not be opened or listed.
enum NestedRepositoryError: LocalizedError {
    /// The folder picked to grant access is not the worktree's.
    case wrongFolder(expected: String)

    var errorDescription: String? {
        switch self {
        case .wrongFolder(let expected):
            "That is not the worktree’s folder. Choose the folder at \(expected)."
        }
    }
}

extension RepositoryBookmark {
    /// The repository this one's folder is inside, for a nested one.
    var nestedParent: UUID? {
        if case .nested(let parent, _) = location { parent } else { nil }
    }

    /// Nested repositories (submodules, worktrees kept inside a repository)
    /// are opened from their repository's sidebar, so the repository list
    /// leaves them out rather than repeating every submodule of every
    /// repository there.
    var isNested: Bool { nestedParent != nil }
}

extension RepositoryLibrary {
    /// The repositories the repository list and quick open show.
    var listedBookmarks: [RepositoryBookmark] {
        bookmarks.filter { !$0.isNested }
    }

    /// The repository listed at a folder, if any.
    func bookmark(at url: URL) -> RepositoryBookmark? {
        let target = Self.comparable(url)
        return bookmarks.first { bookmark in
            (try? resolve(bookmark).url).map(Self.comparable) == target
        }
    }

    /// The bookmark for a submodule or worktree at `url` that belongs with
    /// `parent`, made now when Twig can already reach the folder: inside
    /// `parent`'s folder, in Documents, or in a watched folder. `nil` when
    /// it cannot, and the user has to grant the folder first.
    /// `linkedWorktree` marks it as needing `parent`'s folder as well, where
    /// its git directory is.
    func bookmark(
        forRepositoryAt url: URL, from parent: RepositoryBookmark, linkedWorktree: Bool
    ) -> RepositoryBookmark? {
        if let existing = bookmark(at: url) {
            if linkedWorktree, existing.requires == nil, existing.id != parent.id,
               let index = bookmarks.firstIndex(where: { $0.id == existing.id }) {
                bookmarks[index].requires = parent.id
                sortAndSave()
                return bookmarks[index]
            }
            return existing
        }
        guard let location = reachableLocation(of: url, from: parent) else { return nil }
        return insert(RepositoryBookmark(
            name: url.lastPathComponent, location: location,
            requires: linkedWorktree && location.nestedParent == nil ? parent.id : nil
        ))
    }

    /// Lists a worktree Twig has just made at `url`, while it still holds
    /// the access the folder was picked with: through a location it can
    /// reach anyway, or as a bookmark of its own.
    func addWorktree(at url: URL, main: RepositoryBookmark) throws -> RepositoryBookmark {
        if let bookmark = bookmark(forRepositoryAt: url, from: main, linkedWorktree: true) {
            return bookmark
        }
        return insert(RepositoryBookmark(
            name: url.lastPathComponent, location: .external(try url.repositoryBookmark()), requires: main.id
        ))
    }

    /// Lists a worktree whose folder the user has just granted. The folder
    /// must be the worktree's. `main` is the repository a linked worktree
    /// needs as well; `nil` for a main worktree.
    func addGrantedWorktree(_ picked: URL, expected: URL, main: RepositoryBookmark?) throws -> RepositoryBookmark {
        let isScoped = picked.startAccessingSecurityScopedResource()
        defer {
            if isScoped { picked.stopAccessingSecurityScopedResource() }
        }
        guard Self.comparable(picked) == Self.comparable(expected) else {
            throw NestedRepositoryError.wrongFolder(expected: expected.path(percentEncoded: false))
        }
        var bookmark = try add(picked)
        if let main, bookmark.requires == nil, bookmark.id != main.id, let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index].requires = main.id
            bookmark = bookmarks[index]
            sortAndSave()
        }
        return bookmark
    }

    /// Follows a listed submodule or worktree to `new`, where it moved,
    /// while Twig holds access to `new`.
    func relocate(_ moved: RepositoryBookmark, to new: URL, parent: RepositoryBookmark) {
        guard let index = bookmarks.firstIndex(where: { $0.id == moved.id }) else { return }
        if let location = reachableLocation(of: new, from: parent) {
            bookmarks[index].location = location
        } else if let data = try? new.repositoryBookmark() {
            bookmarks[index].location = .external(data)
        }
        bookmarks[index].name = new.lastPathComponent
        sortAndSave()
    }

    /// Where `url` is, as a location Twig can reach without asking.
    private func reachableLocation(of url: URL, from parent: RepositoryBookmark) -> RepositoryBookmark.Location? {
        let target = Self.comparable(url)
        if let base = (try? resolve(parent).url).map(Self.comparable), let path = Self.path(target, below: base) {
            return .nested(parent: parent.id, path: path)
        }
        if let path = Self.path(target, below: Self.comparable(documents)) {
            return .documents(path)
        }
        for (id, folder) in openFolders {
            if let path = Self.path(target, below: Self.comparable(folder.url)) {
                return .watched(folder: id, path: path)
            }
        }
        return nil
    }

    private func insert(_ bookmark: RepositoryBookmark) -> RepositoryBookmark {
        bookmarks.append(bookmark)
        sortAndSave()
        return bookmark
    }

    /// A folder's path with links resolved and no slash at the end, so
    /// `/var` and `/private/var` compare equal.
    static func comparable(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func path(_ path: String, below base: String) -> String? {
        guard path.count > base.count, path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }
}

extension RepositoryBookmark.Location {
    var nestedParent: UUID? {
        if case .nested(let parent, _) = self { parent } else { nil }
    }
}
