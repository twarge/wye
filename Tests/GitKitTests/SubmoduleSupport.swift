import Foundation
import GitKit

/// A superproject with submodules, built with the command line git from
/// bare repositories on disk that stand as the submodules' remotes.
struct SubmoduleFixture {
    /// Holds everything, so one removal cleans up.
    let folder: URL
    /// The superproject, where GitKit works.
    let main: Fixture

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "GitKitSubmodules-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        main = try Fixture(at: folder.appending(path: "super", directoryHint: .isDirectory))
        try main.commit("README", "superproject\n", message: "Start")
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Makes a bare repository named `name` with commits, returning its URL.
    @discardableResult
    func makeLibrary(_ name: String, commits: [String] = ["One", "Two"]) throws -> URL {
        let work = try Fixture(at: folder.appending(path: "\(name)-work", directoryHint: .isDirectory))
        for (number, message) in commits.enumerated() {
            try work.commit("file.txt", "\(number)\n", message: message)
        }
        let bare = folder.appending(path: "\(name).git", directoryHint: .isDirectory)
        try work.git("clone", "--quiet", "--bare", ".", bare.path)
        return bare
    }

    /// The working copy a bare library was made from, to make more commits
    /// and push them.
    func libraryWork(_ name: String) throws -> Fixture {
        Fixture(existing: folder.appending(path: "\(name)-work", directoryHint: .isDirectory))
    }

    /// Clones `source` into `name` beside the others, without its submodules.
    func clone(_ source: URL, as name: String) throws -> Fixture {
        let target = folder.appending(path: name, directoryHint: .isDirectory)
        _ = try Fixture.run(["clone", "--quiet", source.path, target.path], in: folder)
        let fixture = Fixture(existing: target)
        try fixture.git("config", "user.name", "Test Author")
        try fixture.git("config", "user.email", "author@example.com")
        return fixture
    }
}

extension Fixture {
    /// A repository already on disk.
    init(existing url: URL) {
        self.url = url
    }

    /// A fresh repository at a chosen place.
    init(at url: URL) throws {
        self.init(existing: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "--quiet", "--initial-branch=main")
        try git("config", "user.name", "Test Author")
        try git("config", "user.email", "author@example.com")
    }

    /// git with local paths allowed as submodule sources, which git refuses
    /// by default since 2.38.
    @discardableResult
    func submoduleGit(_ arguments: String...) throws -> String {
        try Self.run(["-c", "protocol.file.allow=always"] + arguments, in: url)
    }
}
