import Foundation
import GitKit
import Testing
@testable import WyeUI

@MainActor
@Suite struct RepositoryLibraryTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "WyeUITests-\(UUID().uuidString)")
    var storage: URL { folder.appending(path: "Repositories.json") }
    var documents: URL { folder.appending(path: "Documents") }

    init() throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "Documents"), withIntermediateDirectories: true)
    }

    /// The list as the first versions saved it: an array of repositories.
    private func writeFirstFormat() throws {
        let json = """
        [
          {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "beta", "location": {"documents": {"_0": "beta"}}},
          {"id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Alpha", "location": {"documents": {"_0": "Alpha"}}}
        ]
        """
        try Data(json.utf8).write(to: storage)
    }

    @Test func readsTheFirstFormat() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeFirstFormat()
        let library = RepositoryLibrary(storage: storage, documents: documents)
        #expect(library.bookmarks.map(\.name) == ["beta", "Alpha"])
        #expect(library.groups.isEmpty)
        #expect(library.bookmarks.allSatisfy { $0.groupID == nil && $0.lastOpened == nil })
    }

    @Test func keepsGroupsBetweenLaunches() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeFirstFormat()
        var library = RepositoryLibrary(storage: storage, documents: documents)
        let work = library.createGroup(named: "Work")
        let alpha = try #require(library.bookmarks.first { $0.name == "Alpha" })
        library.move([alpha.id], to: work.id)
        library.recordOpened(alpha)

        library = RepositoryLibrary(storage: storage, documents: documents)
        #expect(library.groups.map(\.name) == ["Work"])
        let reread = try #require(library.bookmarks.first { $0.id == alpha.id })
        #expect(library.group(of: reread) == work)
        #expect(reread.lastOpened != nil)
        #expect(try LibraryFile.decode(Data(contentsOf: storage)).version == 2)

        library.renameGroup(work, to: "Clients")
        #expect(library.groups.map(\.name) == ["Clients"])
        library.deleteGroup(library.groups[0])
        #expect(library.groups.isEmpty)
        #expect(library.bookmarks.allSatisfy { $0.groupID == nil })
    }

    @Test func sortsByNameOrLastOpened() {
        let old = RepositoryBookmark(name: "b", location: .documents("b"), lastOpened: .distantPast + 10)
        let recent = RepositoryBookmark(name: "c", location: .documents("c"), lastOpened: .now)
        let never = RepositoryBookmark(name: "A", location: .documents("A"))
        #expect(RepositoryListOrder.name.sorted([old, recent, never]).map(\.name) == ["A", "b", "c"])
        #expect(RepositoryListOrder.lastOpened.sorted([old, recent, never]).map(\.name) == ["c", "b", "A"])
    }

    @Test func tellsDraggedRowsFromFolders() {
        let id = UUID()
        #expect(RepositoryDragReference.id(from: RepositoryDragReference.url(for: id)) == id)
        #expect(RepositoryDragReference.id(from: URL(filePath: "/tmp/project")) == nil)
        #expect(!RepositoryDragReference.url(for: id).isFileURL)
    }
}

@MainActor
@Suite struct WatchedFolderTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "WyeUITests-\(UUID().uuidString)")
    var storage: URL { folder.appending(path: "Repositories.json") }
    var documents: URL { folder.appending(path: "Documents") }
    var watched: URL { folder.appending(path: "Repositories") }

    init() throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "Documents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "Repositories"), withIntermediateDirectories: true)
    }

    private func makeRepository(_ path: String, in root: URL) throws {
        _ = try Repository.create(at: root.appending(path: path))
    }

    @Test func listsWhatIsInTheFolderAndFollowsIt() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeRepository("alpha", in: watched)
        try makeRepository("nested/beta", in: watched)
        try FileManager.default.createDirectory(at: watched.appending(path: "notes"), withIntermediateDirectories: true)
        try makeRepository("elsewhere", in: folder)

        let library = RepositoryLibrary(storage: storage, documents: documents)
        let outside = try library.add(folder.appending(path: "elsewhere"))
        try library.watch(watched)
        #expect(library.bookmarks.map(\.name) == ["alpha", "beta", "elsewhere"])
        // Watching the same folder again changes nothing.
        try library.watch(watched)
        #expect(library.folders.count == 1)
        #expect(library.bookmarks.count == 3)

        // A repository arrives and another leaves.
        try makeRepository("gamma", in: watched)
        try FileManager.default.removeItem(at: watched.appending(path: "alpha"))
        library.syncWatchedFolders()
        #expect(library.bookmarks.map(\.name) == ["beta", "elsewhere", "gamma"])

        // The list and the folder survive a relaunch.
        let relaunched = RepositoryLibrary(storage: storage, documents: documents)
        #expect(relaunched.folders.map(\.name) == ["Repositories"])
        #expect(relaunched.bookmarks.map(\.name) == ["beta", "elsewhere", "gamma"])
        let beta = try #require(relaunched.bookmarks.first)
        #expect(try relaunched.access(to: beta).url.lastPathComponent == "beta")

        // One added by hand is never dropped, even when its files go.
        try FileManager.default.removeItem(at: folder.appending(path: "elsewhere"))
        relaunched.syncWatchedFolders()
        #expect(relaunched.bookmarks.contains { $0.id == outside.id })

        relaunched.stopWatching(try #require(relaunched.folders.first))
        #expect(relaunched.bookmarks.map(\.name) == ["elsewhere"])
    }

    @Test func noticesARepositoryArrivingWithoutBeingAsked() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = RepositoryLibrary(storage: storage, documents: documents)
        try library.watch(watched)
        #expect(library.bookmarks.isEmpty)

        try makeRepository("arrived", in: watched)
        for _ in 0..<100 where library.bookmarks.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(library.bookmarks.map(\.name) == ["arrived"])

        try FileManager.default.removeItem(at: watched.appending(path: "arrived"))
        for _ in 0..<100 where !library.bookmarks.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(library.bookmarks.isEmpty)
    }

    @Test func aRepositoryAlreadyAddedIsNotListedTwice() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeRepository("alpha", in: watched)
        let library = RepositoryLibrary(storage: storage, documents: documents)
        let added = try library.add(watched.appending(path: "alpha"))
        try library.watch(watched)
        #expect(library.bookmarks.map(\.id) == [added.id])
    }
}
