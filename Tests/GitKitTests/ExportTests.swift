import Foundation
import GitKit
import Testing

/// Writing a file or a whole folder out as one side of a comparison has it:
/// what previews and drags of a document package, which git keeps as many
/// files, are made from.
@Suite struct ExportTests {
    let fixture: Fixture
    let output: URL

    init() throws {
        fixture = try Fixture()
        output = FileManager.default.temporaryDirectory
            .appending(path: "ExportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func cleanUp() {
        fixture.remove()
        try? FileManager.default.removeItem(at: output)
    }

    private func contents(of folder: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) ?? .init() {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count))
            files[path.hasPrefix("/") ? String(path.dropFirst()) : path] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }

    private func revParse(_ revision: String) throws -> OID {
        try #require(OID(hex: try fixture.git("rev-parse", revision).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func aCommitsFolderIsWrittenWithEveryFileInIt() async throws {
        defer { cleanUp() }
        try fixture.write("one\n", to: "Board.horizontal/board.json")
        try fixture.write("two\n", to: "Board.horizontal/pool/part.json")
        try fixture.write("outside\n", to: "README")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "-m", "Start")
        try fixture.commit("Board.horizontal/board.json", "changed\n", message: "Change")

        let repository = try fixture.open()
        let first = try revParse("HEAD~1")
        let item = try #require(try await repository.export(
            "Board.horizontal", from: .commit(first), to: output.appending(path: "Board.horizontal"), limit: 1 << 20
        ))
        #expect(item.isFolder)
        #expect(item.size == 8)
        #expect(try contents(of: item.url) == ["board.json": "one\n", "pool/part.json": "two\n"])
    }

    @Test func aFileIsWrittenOnItsOwn() async throws {
        defer { cleanUp() }
        let head = try revParse(try fixture.commit("a.txt", "hello\n", message: "Start"))
        let repository = try fixture.open()
        let file = output.appending(path: "a.txt")
        let item = try #require(try await repository.export("a.txt", from: .commit(head), to: file, limit: 100))
        #expect(!item.isFolder)
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello\n")
    }

    @Test func nothingThereIsNil() async throws {
        defer { cleanUp() }
        let head = try revParse(try fixture.commit("a.txt", "hello\n", message: "Start"))
        let repository = try fixture.open()
        let missing = output.appending(path: "Missing.horizontal")
        #expect(try await repository.export("Missing.horizontal", from: .commit(head), to: missing, limit: 100) == nil)
        #expect(try await repository.export("Missing.horizontal", from: .index, to: missing, limit: 100) == nil)
        #expect(try await repository.export("Missing.horizontal", from: .workingTree, to: missing, limit: 100) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func theIndexAndTheWorkingTreeEachHaveTheirOwn() async throws {
        defer { cleanUp() }
        try fixture.write("committed\n", to: "Doc.rtfd/TXT.rtf")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "-m", "Start")
        try fixture.write("staged\n", to: "Doc.rtfd/TXT.rtf")
        try fixture.git("add", ".")
        try fixture.write("on disk\n", to: "Doc.rtfd/TXT.rtf")
        try fixture.write("untracked\n", to: "Doc.rtfd/image.png")

        let repository = try fixture.open()
        let staged = try #require(try await repository.export(
            "Doc.rtfd", from: .index, to: output.appending(path: "index/Doc.rtfd"), limit: 1 << 20
        ))
        #expect(try contents(of: staged.url) == ["TXT.rtf": "staged\n"])
        let disk = try #require(try await repository.export(
            "Doc.rtfd", from: .workingTree, to: output.appending(path: "disk/Doc.rtfd"), limit: 1 << 20
        ))
        #expect(try contents(of: disk.url) == ["TXT.rtf": "on disk\n", "image.png": "untracked\n"])
    }

    @Test func theWholeWorkingTreeLeavesOutGit() async throws {
        defer { cleanUp() }
        try fixture.commit("board.json", "one\n", message: "Start")
        let repository = try fixture.open()
        let item = try #require(try await repository.export(
            "", from: .workingTree, to: output.appending(path: "Root.horizontal"), limit: 1 << 20
        ))
        #expect(try contents(of: item.url) == ["board.json": "one\n"])
        let head = try revParse("HEAD")
        let tree = try #require(try await repository.export(
            "", from: .commit(head), to: output.appending(path: "Head.horizontal"), limit: 1 << 20
        ))
        #expect(try contents(of: tree.url) == ["board.json": "one\n"])
    }

    @Test func overTheLimitWritesNothing() async throws {
        defer { cleanUp() }
        try fixture.write(String(repeating: "x", count: 600), to: "Big.horizontal/a.json")
        try fixture.write(String(repeating: "y", count: 600), to: "Big.horizontal/b.json")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "-m", "Start")
        let head = try revParse("HEAD")

        let repository = try fixture.open()
        let destination = output.appending(path: "Big.horizontal")
        for source in [ContentSource.commit(head), .index, .workingTree] {
            await #expect(throws: ExportTooLarge.self) {
                try await repository.export("Big.horizontal", from: source, to: destination, limit: 1_000)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func diffsSayWhereEachSideCameFrom() async throws {
        defer { cleanUp() }
        let first = try revParse(try fixture.commit("a.txt", "one\n", message: "Start"))
        let second = try revParse(try fixture.commit("a.txt", "two\n", message: "Change"))
        try fixture.write("three\n", to: "a.txt")
        try fixture.git("add", ".")
        try fixture.write("four\n", to: "a.txt")

        let repository = try fixture.open()

        let root = try #require(try await repository.changes(in: first).first)
        #expect(root.oldSource == nil)
        #expect(root.newSource == .commit(first))
        let change = try #require(try await repository.changes(in: second).first)
        #expect(change.oldSource == .commit(first))
        #expect(change.newSource == .commit(second))

        let staged = try #require(try await repository.stagedDiff(of: "a.txt"))
        #expect(staged.oldSource == .commit(second))
        #expect(staged.newSource == .index)
        let unstaged = try #require(try await repository.unstagedDiff(of: "a.txt"))
        #expect(unstaged.oldSource == .index)
        #expect(unstaged.newSource == .workingTree)
        #expect(unstaged.newSideIsWorkingTree)

        let sinceFirst = try #require(try await repository.changes(since: first).first)
        #expect(sinceFirst.oldSource == .commit(first))
        #expect(sinceFirst.newSource == .workingTree)
        let cached = try #require(try await repository.changes(in: .indexToHead).first)
        #expect(cached.oldSource == .commit(second))
        #expect(cached.newSource == .index)

        // What a side came from writes it out as that side has it.
        let file = output.appending(path: "a.txt")
        _ = try await repository.export("a.txt", from: try #require(change.oldSource), to: file, limit: 100)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\n")
    }
}
