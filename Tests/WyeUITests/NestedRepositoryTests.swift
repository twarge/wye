import Foundation
import GitKit
import Testing
@testable import WyeUI

/// Submodules and worktrees in the repository list: reached through their
/// repository's folder, kept out of the list, and saved compatibly.
@MainActor
@Suite struct NestedRepositoryTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "WyeUITests-\(UUID().uuidString)")
    var storage: URL { folder.appending(path: "Repositories.json") }
    var documents: URL { folder.appending(path: "Documents") }

    init() throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "Documents"), withIntermediateDirectories: true)
    }

    @Test func readsListsSavedBeforeNestedRepositories() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // Version 2 as saved before `requires` and `.nested`.
        let json = """
        {"version": 2, "groups": [], "folders": [],
         "repositories": [
          {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "app", "location": {"documents": {"_0": "app"}}}
         ]}
        """
        let file = try LibraryFile.decode(Data(json.utf8))
        #expect(file.repositories.count == 1)
        #expect(file.repositories[0].requires == nil)
        #expect(!file.repositories[0].isNested)
    }

    @Test func savesAndReadsNestedLocations() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let parent = RepositoryBookmark(name: "app", location: .documents("app"))
        let nested = RepositoryBookmark(name: "lib", location: .nested(parent: parent.id, path: "vendor/lib"))
        let linked = RepositoryBookmark(name: "app-topic", location: .documents("app-topic"), requires: parent.id)
        let saved = try LibraryFile(repositories: [parent, nested, linked], groups: []).encoded()
        let read = try LibraryFile.decode(saved)
        #expect(read.repositories == [parent, nested, linked])
        #expect(read.repositories[1].nestedParent == parent.id)
    }

    @Test func opensASubmoduleThroughItsRepositoryAndKeepsItOutOfTheList() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = documents.appending(path: "app")
        _ = try Repository.create(at: app)
        _ = try Repository.create(at: app.appending(path: "vendor/lib"))
        let library = RepositoryLibrary(storage: storage, documents: documents)
        let parent = try #require(library.bookmarks.first)

        let nested = try #require(library.bookmark(
            forRepositoryAt: app.appending(path: "vendor/lib"), from: parent, linkedWorktree: false
        ))
        #expect(nested.location == .nested(parent: parent.id, path: "vendor/lib"))
        #expect(library.listedBookmarks.map(\.id) == [parent.id])
        // Asking again finds the same one.
        #expect(library.bookmark(forRepositoryAt: app.appending(path: "vendor/lib"), from: parent, linkedWorktree: false)?.id == nested.id)
        #expect(try RepositoryLibrary.comparable(library.access(to: nested).url) == RepositoryLibrary.comparable(app.appending(path: "vendor/lib")))

        // A relaunch keeps it; forgetting the repository forgets it too.
        let relaunched = RepositoryLibrary(storage: storage, documents: documents)
        #expect(relaunched.bookmarks.count == 2)
        relaunched.remove(try #require(relaunched.bookmarks.first { $0.id == parent.id }))
        #expect(relaunched.bookmarks.isEmpty)
    }

    @Test func listsAWorktreeElsewhereAsNeedingItsRepository() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = documents.appending(path: "app")
        _ = try Repository.create(at: app)
        let library = RepositoryLibrary(storage: storage, documents: documents)
        let parent = try #require(library.bookmarks.first)

        // In Documents, beside its repository: reachable, and needing it.
        let topic = documents.appending(path: "app-topic")
        try FileManager.default.createDirectory(at: topic, withIntermediateDirectories: true)
        let listed = try #require(library.bookmark(forRepositoryAt: topic, from: parent, linkedWorktree: true))
        #expect(listed.location == .documents("app-topic"))
        #expect(listed.requires == parent.id)
        #expect(library.listedBookmarks.contains { $0.id == listed.id })

        // Somewhere Wye was never given: nothing until the user grants it.
        #expect(library.bookmark(forRepositoryAt: folder.appending(path: "elsewhere"), from: parent, linkedWorktree: true) == nil)

        // Moving it follows it.
        let moved = documents.appending(path: "app-moved")
        try FileManager.default.moveItem(at: topic, to: moved)
        library.relocate(listed, to: moved, parent: parent)
        #expect(library.bookmarks.first { $0.id == listed.id }?.location == .documents("app-moved"))
    }

    @Test func findsASubmodulesGitDirectoryInItsRepository() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = folder.appending(path: "main")
        let submodule = main.appending(path: "lib")
        try FileManager.default.createDirectory(at: main.appending(path: ".git/modules/lib"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        try "gitdir: ../.git/modules/lib\n".write(to: submodule.appending(path: ".git"), atomically: true, encoding: .utf8)
        let real = RepositoryLocations.realPath(folder.path)
        let locations = RepositoryLocations(repositoryURL: submodule, isBare: false)
        #expect(locations.workTree == real + "/main/lib")
        #expect(locations.gitDirectory == real + "/main/.git/modules/lib")
        #expect(locations.commonDirectory == locations.gitDirectory)
        // The parent's own watcher sees the submodule's checkout move.
        let parent = RepositoryChangeFilter(locations: RepositoryLocations(repositoryURL: main, isBare: false))
        #expect(parent.classify(real + "/main/.git/modules/lib/HEAD") == .gitDirectory)
        #expect(parent.classify(real + "/main/lib/file.txt") == .workingTree("lib/file.txt"))
    }
}
