import Foundation
import GitKit
import Testing

@Suite struct TreeTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    private func makeTree() throws -> String {
        try fixture.write("hello\n", to: "README.md")
        try fixture.write("#!/bin/sh\necho hi\n", to: "tools/run.sh")
        try fixture.write("let a = 1\n", to: "Sources/App/main.swift")
        try fixture.write("let b = 2\n", to: "Sources/App/b.swift")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x00, 0xFF]).write(to: fixture.url.appending(path: "image.png"))
        try FileManager.default.createSymbolicLink(atPath: fixture.url.appending(path: "link").path, withDestinationPath: "README.md")
        try fixture.git("add", ".")
        try fixture.git("update-index", "--chmod=+x", "tools/run.sh")
        try fixture.git("commit", "--quiet", "-m", "Files")
        return try fixture.git("rev-parse", "HEAD")
    }

    /// `git ls-tree` as (mode, oid, name) triples.
    private func lsTree(_ treeish: String) throws -> [(mode: String, oid: String, name: String)] {
        try fixture.git("ls-tree", treeish).split(separator: "\n").map { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            let fields = parts[0].split(separator: " ")
            return (String(fields[0]), String(fields[2]), String(parts[1]))
        }
    }

    private func mode(of kind: TreeEntry.Kind) -> String {
        switch kind {
        case .directory: "040000"
        case .file: "100644"
        case .executable: "100755"
        case .symlink: "120000"
        case .submodule: "160000"
        }
    }

    @Test func entriesMatchLsTree() async throws {
        defer { fixture.remove() }
        let head = try makeTree()
        let id = try #require(OID(hex: head))
        let repository = try fixture.open()

        for directory in ["", "Sources", "Sources/App", "tools"] {
            let entries = try await repository.treeEntries(in: id, at: directory)
            let expected = try lsTree(directory.isEmpty ? "HEAD" : "HEAD:\(directory)")
            #expect(entries.map(\.name) == expected.map(\.name), "\(directory)")
            #expect(entries.map(\.objectID.hex) == expected.map(\.oid))
            #expect(entries.map { mode(of: $0.kind) } == expected.map(\.mode))
            #expect(entries.map(\.path) == expected.map { directory.isEmpty ? $0.name : "\(directory)/\($0.name)" })
        }
        await #expect(throws: GitError.self) { try await repository.treeEntries(in: id, at: "README.md") }
        await #expect(throws: GitError.self) { try await repository.treeEntries(in: id, at: "nowhere") }
    }

    @Test func fileContentsMatchGitShow() async throws {
        defer { fixture.remove() }
        let head = try makeTree()
        let id = try #require(OID(hex: head))
        let repository = try fixture.open()

        let readme = try await repository.fileContent(at: "README.md", in: id)
        #expect(readme.contents == .text("hello\n"))
        #expect(readme.objectID.hex == (try fixture.git("rev-parse", "HEAD:README.md")))
        #expect(readme.size == Int(try fixture.git("cat-file", "-s", "HEAD:README.md")))

        let nested = try await repository.fileContent(at: "Sources/App/main.swift", in: id)
        #expect(nested.contents == .text(try fixture.git("show", "HEAD:Sources/App/main.swift") + "\n"))

        let image = try await repository.fileContent(at: "image.png", in: id)
        #expect(image.contents == .binary(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x00, 0xFF])))

        let link = try await repository.fileContent(at: "link", in: id)
        #expect(link.contents == .text("README.md"))

        let capped = try await repository.fileContent(at: "tools/run.sh", in: id, limit: 4)
        #expect(capped.contents == .tooLarge)
        #expect(capped.size == Int(try fixture.git("cat-file", "-s", "HEAD:tools/run.sh")))

        await #expect(throws: GitError.self) { try await repository.fileContent(at: "Sources", in: id) }
        await #expect(throws: GitError.self) { try await repository.fileContent(at: "missing", in: id) }
    }

    @Test func olderCommitsShowTheirOwnTree() async throws {
        defer { fixture.remove() }
        let first = try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.commit("b.txt", "two\n", message: "Second")
        try fixture.commit("a.txt", "changed\n", message: "Third")
        let repository = try fixture.open()
        let entries = try await repository.treeEntries(in: OID(hex: first)!)
        #expect(entries.map(\.name) == ["a.txt"])
        #expect(try await repository.fileContent(at: "a.txt", in: OID(hex: first)!).contents == .text("one\n"))
    }
}
