import Foundation
import GitKit
import Testing

/// Exporting a commit's files as a zip, unpacked with `/usr/bin/unzip` and
/// compared with what `git archive` writes for the same commit.
@Suite struct ArchiveTests {
    let fixture: Fixture
    let scratch: URL

    init() throws {
        fixture = try Fixture()
        scratch = fixture.url.appendingPathExtension("archives")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try fixture.write("hello\n", to: "README.md")
        try fixture.write("#!/bin/sh\necho hi\n", to: "bin/run.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fixture.url.appending(path: "bin/run.sh").path)
        try fixture.write(String(repeating: "compressible line\n", count: 500), to: "docs/long.txt")
        try fixture.write("", to: "docs/empty.txt")
        // Not text in the name: macOS's unzip mangles names outside ASCII.
        try fixture.write("naïve ünïcode\n", to: "docs/spaced name.txt")
        // Bytes that are not text, all 256 of them.
        let binary = Data((0...255).map { UInt8($0) })
        try binary.write(to: fixture.url.appending(path: "image.bin"))
        try FileManager.default.createSymbolicLink(atPath: fixture.url.appending(path: "link").path,
                                                   withDestinationPath: "docs/long.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "--quiet", "-m", "Files")
    }

    private func remove() {
        fixture.remove()
    }

    private func unzip(_ archive: URL, into name: String) throws -> URL {
        let folder = scratch.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", "-q", archive.path, "-d", folder.path)
        return folder
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError(message: "\(tool) \(arguments.joined(separator: " ")) failed")
        }
    }

    /// Every file and link under a folder, relative to it, with what
    /// identifies it: contents and executable bit, or a link's target.
    private func inventory(of folder: URL) throws -> [String: String] {
        var items: [String: String] = [:]
        let manager = FileManager.default
        let paths = try manager.subpathsOfDirectory(atPath: folder.path)
        for path in paths {
            let full = folder.appending(path: path).path
            let attributes = try manager.attributesOfItem(atPath: full)
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink:
                items[path] = "link → " + (try manager.destinationOfSymbolicLink(atPath: full))
            case .typeRegular:
                let permissions = (attributes[.posixPermissions] as? Int ?? 0) & 0o111 != 0 ? "x" : "-"
                let data = try Data(contentsOf: URL(filePath: full))
                items[path] = "\(permissions) \(data.base64EncodedString())"
            default:
                items[path + "/"] = "folder"
            }
        }
        return items
    }

    @Test func theArchiveHoldsWhatGitArchiveHolds() async throws {
        defer { remove() }
        let ours = scratch.appending(path: "ours.zip")
        let theirs = scratch.appending(path: "theirs.zip")
        let id = try #require(OID(hex: try fixture.git("rev-parse", "HEAD")))
        let summary = try await fixture.open().writeArchive(of: id, to: ours)
        try fixture.git("archive", "--format=zip", "-o", theirs.path, "HEAD")

        #expect(summary.files == 7)
        #expect(summary.submodules == 0)
        let ourFiles = try inventory(of: unzip(ours, into: "ours"))
        let gitFiles = try inventory(of: unzip(theirs, into: "theirs"))
        #expect(ourFiles == gitFiles)
        #expect(ourFiles["bin/run.sh"]?.hasPrefix("x ") == true)
        #expect(ourFiles["README.md"]?.hasPrefix("- ") == true)
        #expect(ourFiles["link"] == "link → docs/long.txt")
        // unzip checks every entry's CRC; -t says so for the whole archive.
        try run("/usr/bin/unzip", "-tq", ours.path)
    }

    @Test func aPrefixGoesBeforeEveryPath() async throws {
        defer { remove() }
        let ours = scratch.appending(path: "ours.zip")
        let theirs = scratch.appending(path: "theirs.zip")
        let id = try #require(OID(hex: try fixture.git("rev-parse", "HEAD")))
        try await fixture.open().writeArchive(of: id, to: ours, prefix: "project-main")
        try fixture.git("archive", "--format=zip", "--prefix=project-main/", "-o", theirs.path, "HEAD")
        #expect(try inventory(of: unzip(ours, into: "ours")) == inventory(of: unzip(theirs, into: "theirs")))
    }

    @Test func submodulesAreEmptyFolders() async throws {
        defer { remove() }
        // A gitlink, without cloning anything: the commit need not exist here.
        let head = try fixture.git("rev-parse", "HEAD")
        try fixture.git("update-index", "--add", "--cacheinfo", "160000,\(head),vendor/lib")
        try fixture.git("commit", "--quiet", "-m", "Submodule")
        let id = try #require(OID(hex: try fixture.git("rev-parse", "HEAD")))
        let ours = scratch.appending(path: "ours.zip")
        let summary = try await fixture.open().writeArchive(of: id, to: ours)
        #expect(summary.submodules == 1)
        let files = try inventory(of: unzip(ours, into: "ours"))
        #expect(files["vendor/lib/"] == "folder")
        #expect(!files.keys.contains { $0.hasPrefix("vendor/lib/") && $0 != "vendor/lib/" })
    }
}
