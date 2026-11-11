import Foundation
import GitKit
import Testing
@testable import WyeUI

/// Repositories in the Files location's storage on iOS: listed, saved, and
/// moved there from Documents.
@MainActor
@Suite struct FilesLocationLibraryTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "WyeUITests-\(UUID().uuidString)")
    var storage: URL { folder.appending(path: "Repositories.json") }
    var documents: URL { folder.appending(path: "Documents") }
    var files: URL { folder.appending(path: "File Provider Storage") }

    init() throws {
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }

    private func library() -> RepositoryLibrary {
        RepositoryLibrary(storage: storage, documents: documents, filesStorage: files)
    }

    @Test func savesAndReadsTheFilesLocation() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let bookmark = RepositoryBookmark(name: "app", location: .files("app"))
        let saved = try LibraryFile(repositories: [bookmark], groups: []).encoded()
        #expect(String(decoding: saved, as: UTF8.self).contains(#""files":{"_0":"app"}"#))
        #expect(try LibraryFile.decode(saved).repositories == [bookmark])
    }

    @Test func readsListsSavedBeforeTheFilesLocation() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = """
        {"version": 2, "groups": [], "folders": [],
         "repositories": [
          {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "app", "location": {"documents": {"_0": "app"}}}
         ]}
        """
        let file = try LibraryFile.decode(Data(json.utf8))
        #expect(file.repositories.map(\.location) == [.documents("app")])
    }

    @Test func listsAndResolvesRepositoriesInTheStorage() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Repository.create(at: files.appending(path: "app"))
        _ = try Repository.create(at: documents.appending(path: "old"))
        let library = library()
        let app = try #require(library.bookmarks.first { $0.name == "app" })
        #expect(app.location == .files("app"))
        #expect(try RepositoryLibrary.comparable(library.resolve(app).url) == RepositoryLibrary.comparable(files.appending(path: "app")))
        #expect(library.bookmarks.first { $0.name == "old" }?.location == .documents("old"))
        // Adding it again finds the same one.
        #expect(try library.add(files.appending(path: "app")).id == app.id)
    }

    @Test func aFilesBookmarkDoesNotResolveWithoutTheLocation() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = RepositoryLibrary(storage: storage, documents: documents, filesStorage: nil)
        #expect(throws: (any Error).self) { try library.resolve(RepositoryBookmark(name: "app", location: .files("app"))) }
    }

    @Test func newRepositoriesGoToTheFilesLocationWhereThereIsOne() {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(library().newRepositoryFolder == files.standardizedFileURL)
        #expect(RepositoryLibrary(storage: storage, documents: documents, filesStorage: nil).newRepositoryFolder == documents.standardizedFileURL)
    }

    @Test func movesARepositoryAndKeepsItsBookmark() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Repository.create(at: documents.appending(path: "app"))
        _ = try Repository.create(at: documents.appending(path: "app/vendor/lib"))
        try Data("notes\n".utf8).write(to: documents.appending(path: "app/notes.txt"))
        var library = library()
        let group = library.createGroup(named: "Work")
        let app = try #require(library.bookmarks.first)
        library.move([app.id], to: group.id)
        library.recordOpened(app)
        let lib = try #require(library.bookmark(
            forRepositoryAt: documents.appending(path: "app/vendor/lib"), from: app, linkedWorktree: false
        ))
        #expect(library.canMoveToFilesLocation(app))
        #expect(library.repositoriesInDocuments.map(\.id) == [app.id])

        try library.moveToFilesLocation(app)

        let moved = try #require(library.bookmarks.first { $0.id == app.id })
        #expect(moved.location == .files("app"))
        #expect(moved.groupID == group.id)
        #expect(moved.lastOpened != nil)
        #expect(!FileManager.default.fileExists(atPath: documents.appending(path: "app").path(percentEncoded: false)))
        #expect(try String(contentsOf: library.resolve(moved).url.appending(path: "notes.txt"), encoding: .utf8) == "notes\n")
        // The submodule is still reached through it.
        #expect(try RepositoryLibrary.comparable(library.access(to: lib).url)
            == RepositoryLibrary.comparable(files.appending(path: "app/vendor/lib")))
        #expect(library.repositoriesInDocuments.isEmpty)
        #expect(!library.canMoveToFilesLocation(moved))

        // And so after a relaunch.
        library = self.library()
        #expect(library.bookmarks.first { $0.id == app.id }?.location == .files("app"))
        #expect(library.bookmarks.filter { $0.name == "app" }.count == 1)
    }

    @Test func aFailedMoveLeavesTheRepositoryWhereItWas() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Repository.create(at: documents.appending(path: "app"))
        try FileManager.default.createDirectory(at: files.appending(path: "app"), withIntermediateDirectories: true)
        let library = library()
        let app = try #require(library.bookmarks.first { $0.location == .documents("app") })
        #expect(throws: (any Error).self) { try library.moveToFilesLocation(app) }
        #expect(library.bookmarks.first { $0.id == app.id }?.location == .documents("app"))
        #expect(Repository.exists(at: documents.appending(path: "app")))
        let failures = library.moveAllToFilesLocation()
        #expect(failures.map(\.name) == ["app"])
    }

    @Test func leavesRepositoriesFromElsewhereAlone() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let elsewhere = folder.appending(path: "Elsewhere/app")
        _ = try Repository.create(at: elsewhere)
        let library = library()
        let added = try library.add(elsewhere)
        guard case .external = added.location else {
            Issue.record("Expected an external bookmark, got \(added.location)")
            return
        }
        #expect(!library.canMoveToFilesLocation(added))
        #expect(!RepositoryLibrary(storage: storage, documents: documents, filesStorage: nil)
            .canMoveToFilesLocation(RepositoryBookmark(name: "x", location: .documents("x"))))
    }
}
