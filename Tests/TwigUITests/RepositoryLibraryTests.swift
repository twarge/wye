import Foundation
import Testing
@testable import TwigUI

@MainActor
@Suite struct RepositoryLibraryTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "TwigUITests-\(UUID().uuidString)")
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
