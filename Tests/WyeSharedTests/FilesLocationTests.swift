import Foundation
import Testing
@testable import WyeShared

@Suite struct FilesPathTests {
    let storage = URL(filePath: "/tmp/WyeFiles-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func identifiersAreThePathBelowTheStorage() throws {
        let path = try #require(FilesPath(identifier: "app/Sources/main.swift"))
        #expect(path.components == ["app", "Sources", "main.swift"])
        #expect(path.identifier == "app/Sources/main.swift")
        #expect(path.url(in: storage) == storage.appending(path: "app/Sources/main.swift"))
        #expect(FilesPath(url: path.url(in: storage), in: storage) == path)
        #expect(path.parent == FilesPath(identifier: "app/Sources"))
        #expect(path.repository == FilesPath(identifier: "app"))
        #expect(path.name == "main.swift")
    }

    @Test func theTopLevelHasNoIdentifierOfItsOwn() {
        #expect(FilesPath.root.identifier == nil)
        #expect(FilesPath.root.isRoot)
        #expect(FilesPath.root.parent == nil)
        #expect(FilesPath(url: storage, in: storage) == .root)
        #expect(FilesPath(url: storage.appending(path: "/"), in: storage) == .root)
        #expect(FilesPath(identifier: "") == nil)
    }

    @Test func refusesPathsOutsideTheStorage() {
        #expect(FilesPath(url: URL(filePath: "/tmp/elsewhere/file"), in: storage) == nil)
        #expect(FilesPath(url: URL(filePath: "/tmp/" + storage.lastPathComponent + "-sibling/file"), in: storage) == nil)
        #expect(FilesPath(identifier: "app/../../etc/passwd") == nil)
        #expect(FilesPath(identifier: "../app") == nil)
        #expect(FilesPath(identifier: "app//file") == nil)
        #expect(FilesPath(identifier: "app/./file") == nil)
        #expect(FilesPath(identifier: "/app") == nil)
    }

    @Test(arguments: [
        "app/.git", "app/.git/config", "app/.git/objects/ab", "app/vendor/lib/.git",
        "app/.GIT/HEAD", "app/.Git"
    ])
    func hidesGitsOwnData(identifier: String) {
        #expect(FilesPath(identifier: identifier) == nil)
        #expect(FilesPath(url: storage.appending(path: identifier), in: storage) == nil)
    }

    @Test(arguments: [".gitignore", ".github", ".gitattributes", ".gitmodules", ".git-blame-ignore-revs", "git", ".env", ".git.bak"])
    func showsNamesThatOnlyStartWithGit(name: String) throws {
        #expect(!FilesLocation.isHidden(name))
        let parent = try #require(FilesPath(identifier: "app"))
        #expect(FilesLocation.isListed(name, isDirectory: false, in: parent))
        #expect(FilesLocation.isListed(name, isDirectory: true, in: parent))
        #expect(FilesPath(identifier: "app/\(name)") != nil)
    }

    @Test func hidesTheGitFileOfAWorktreeOrSubmodule() throws {
        let worktree = try #require(FilesPath(identifier: "app-topic"))
        let submodule = try #require(FilesPath(identifier: "app/Vendor/library"))
        #expect(!FilesLocation.isListed(".git", isDirectory: false, in: worktree))
        #expect(!FilesLocation.isListed(".git", isDirectory: false, in: submodule))
        #expect(!FilesLocation.isListed(".git", isDirectory: true, in: worktree))
    }

    @Test func theTopLevelListsOnlyRepositoryFolders() {
        #expect(FilesLocation.isListed("app", isDirectory: true, in: .root))
        #expect(!FilesLocation.isListed("notes.txt", isDirectory: false, in: .root))
        #expect(!FilesLocation.isListed(".Trash", isDirectory: true, in: .root))
    }

    @Test func refusesNamesThatAreNotOneComponent() {
        for name in ["", ".", "..", "a/b", ".git", ".GIT", "a\0b"] {
            #expect(!FilesLocation.isAllowedName(name), "\(name)")
        }
        #expect(FilesLocation.isAllowedName(".gitignore"))
        #expect(FilesLocation.isAllowedName("README.md"))
    }

    @Test func namesTheLinkNotItsTarget() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WyeSharedTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = folder.appending(path: "app")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: repository.appending(path: "target.txt"))
        try FileManager.default.createSymbolicLink(
            at: repository.appending(path: "link.txt"), withDestinationURL: repository.appending(path: "target.txt")
        )
        #expect(FilesPath(url: repository.appending(path: "link.txt"), in: folder)?.identifier == "app/link.txt")
    }
}

@Suite struct FilesPermissionTests {
    @Test func theTopLevelIsOnlyRead() {
        #expect(FilesPermissions.of(.root) == .read)
    }

    @Test func aRepositoryFolderTakesNewItemsButStays() throws {
        let repository = try #require(FilesPath(identifier: "app"))
        let permissions = FilesPermissions.of(repository)
        #expect(permissions.contains(.read) && permissions.contains(.write))
        #expect(!permissions.contains(.rename))
        #expect(!permissions.contains(.move))
        #expect(!permissions.contains(.delete))
    }

    @Test func itemsInARepositoryAllowEverything() throws {
        let file = try #require(FilesPath(identifier: "app/Sources/main.swift"))
        #expect(FilesPermissions.of(file) == [.read, .write, .rename, .move, .delete])
    }

    @Test func movesStayInsideRepositories() throws {
        let file = try #require(FilesPath(identifier: "app/a.txt"))
        let folder = try #require(FilesPath(identifier: "app/Sources"))
        let other = try #require(FilesPath(identifier: "site"))
        let repository = try #require(FilesPath(identifier: "app"))
        #expect(FilesPermissions.canMove(file, into: folder, as: "a.txt"))
        #expect(FilesPermissions.canMove(file, into: other, as: "a.txt"))
        #expect(!FilesPermissions.canMove(file, into: .root, as: "a.txt"))
        #expect(!FilesPermissions.canMove(file, into: folder, as: ".git"))
        #expect(!FilesPermissions.canMove(repository, into: other, as: "app"))
        #expect(!FilesPermissions.canMove(folder, into: try #require(FilesPath(identifier: "app/Sources/inner")), as: "Sources"))
    }
}

@Suite(.serialized) struct FilesObservedFolderTests {
    let file = FileManager.default.temporaryDirectory.appending(path: "WyeSharedTests-\(UUID().uuidString).json")

    @Test func listsTheFoldersBeingLookedAtInARepository() throws {
        FilesObservedFolders.fileURLOverride = file
        defer {
            FilesObservedFolders.fileURLOverride = nil
            try? FileManager.default.removeItem(at: file)
        }
        let app = try #require(FilesPath(identifier: "app"))
        let sources = try #require(FilesPath(identifier: "app/Sources"))
        let site = try #require(FilesPath(identifier: "site/pages"))
        let old = try #require(FilesPath(identifier: "app/Old"))
        FilesObservedFolders.note(sources)
        FilesObservedFolders.note(site)
        FilesObservedFolders.note(old, now: .now - 7200)
        #expect(FilesObservedFolders.folders(in: app) == [.root, app, sources])
        FilesObservedFolders.forget(sources)
        #expect(FilesObservedFolders.folders(in: app) == [.root, app])
    }
}

@Suite struct FilesLocationMoveTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "WyeSharedTests-\(UUID().uuidString)")
    var documents: URL { folder.appending(path: "Documents") }
    var storage: URL { folder.appending(path: "File Provider Storage") }

    private func makeRepository(_ name: String, gitFile: Bool = false) throws -> URL {
        let url = documents.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if gitFile {
            try Data("gitdir: /elsewhere/.git/worktrees/\(name)\n".utf8).write(to: url.appending(path: ".git"))
        } else {
            try FileManager.default.createDirectory(at: url.appending(path: ".git/refs"), withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: url.appending(path: ".git/HEAD"))
        }
        try Data("hello\n".utf8).write(to: url.appending(path: "README.md"))
        return url
    }

    @Test func movesTheFolderWithEverythingInIt() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try makeRepository("app")
        let moved = try FilesLocation.moveRepository(at: source, into: storage)
        #expect(moved.lastPathComponent == "app")
        #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        #expect(try String(contentsOf: moved.appending(path: "README.md"), encoding: .utf8) == "hello\n")
        #expect(FileManager.default.fileExists(atPath: moved.appending(path: ".git/HEAD").path(percentEncoded: false)))
    }

    @Test func refusesANameAlreadyThereAndLeavesTheOriginal() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try makeRepository("app")
        try FileManager.default.createDirectory(at: storage.appending(path: "app"), withIntermediateDirectories: true)
        #expect(throws: FilesLocationMoveError.nameTaken("app")) {
            try FilesLocation.moveRepository(at: source, into: storage)
        }
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "README.md").path(percentEncoded: false)))
    }

    @Test func refusesWorktreesEitherWay() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let linked = try makeRepository("app-topic", gitFile: true)
        #expect(throws: FilesLocationMoveError.linkedWorktree("app-topic")) {
            try FilesLocation.moveRepository(at: linked, into: storage)
        }
        let main = try makeRepository("app")
        try FileManager.default.createDirectory(at: main.appending(path: ".git/worktrees/app-topic"), withIntermediateDirectories: true)
        #expect(throws: FilesLocationMoveError.hasWorktrees("app")) {
            try FilesLocation.moveRepository(at: main, into: storage)
        }
        #expect(FileManager.default.fileExists(atPath: main.path(percentEncoded: false)))
    }

    @Test func refusesAFolderThatIsNotARepository() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = documents.appending(path: "notes")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(throws: FilesLocationMoveError.notARepository("notes")) {
            try FilesLocation.moveRepository(at: plain, into: storage)
        }
    }
}
