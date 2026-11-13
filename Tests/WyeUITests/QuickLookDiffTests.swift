import CoreGraphics
import Foundation
import GitKit
import Testing
@testable import WyeUI

private let oldCommit = OID(hex: String(repeating: "1", count: 40))!
private let newCommit = OID(hex: String(repeating: "2", count: 40))!

private func file(
    _ path: String, oldPath: String? = nil, change: FileChange = .modified, isBinary: Bool = false,
    old: ContentSource? = .commit(oldCommit), new: ContentSource? = .commit(newCommit)
) -> FileDiff {
    var file = FileDiff(
        change: change, oldPath: oldPath ?? path, path: path, isBinary: isBinary, additions: 0, deletions: 0,
        hunks: [], isTruncated: false
    )
    file.oldSource = old
    file.newSource = new
    return file
}

/// Packages by a made-up extension, so the tests do not depend on what
/// apps are installed.
private func isBoard(_ pathExtension: String) -> Bool {
    pathExtension == "horizontal"
}

/// Which changed files are shown as pictures, how a document package's
/// files are gathered into one picture, and what the copies written for
/// Quick Look and drags are called.
@Suite struct QuickLookDiffTests {
    @Test func imagesAreDecodedAndOtherBinaryFilesGoToQuickLook() {
        let photo = file("Art/photo.PNG", isBinary: true)
        #expect(VisualDiffView.subject(for: photo) == .image(photo))
        let slides = file("Talks/Launch.key", isBinary: true)
        #expect(VisualDiffView.subject(for: slides) == .quickLook(slides))
        // Text is a text diff, even where Quick Look could draw it.
        #expect(VisualDiffView.subject(for: file("logo.svg")) == nil)
        #expect(VisualDiffView.subject(for: file("Sources/main.swift")) == nil)
        // Nothing to write out on either side.
        #expect(VisualDiffView.subject(for: file("a.key", isBinary: true, old: nil, new: nil)) == nil)
    }

    @Test func aKindQuickLookHadNoPictureOfIsNotTriedAgain() {
        let key = QuickLookTypes.key(for: "Design.qltestnopicture", isFolder: false)
        #expect(key == "file:qltestnopicture")
        #expect(QuickLookTypes.key(for: "Board.Horizontal", isFolder: true) == "folder:horizontal")
        let design = file("Design.qltestnopicture", isBinary: true)
        #expect(VisualDiffView.subject(for: design) == .quickLook(design))
        QuickLookTypes.setHasNoPreview(key)
        #expect(VisualDiffView.subject(for: design) == nil)
    }

    @Test func eachSideIsWhereTheFileWasOrIs() {
        let added = file("new.key", change: .added, old: .commit(oldCommit))
        #expect(added.oldItem == nil)
        #expect(added.newItem == PreviewItem(path: "new.key", source: .commit(newCommit)))
        let deleted = file("gone.key", change: .deleted)
        #expect(deleted.oldItem == PreviewItem(path: "gone.key", source: .commit(oldCommit)))
        #expect(deleted.newItem == nil)
        let renamed = file("b.key", oldPath: "a.key", change: .renamed, old: .index, new: .workingTree)
        #expect(renamed.oldItem == PreviewItem(path: "a.key", source: .index))
        #expect(renamed.newItem == PreviewItem(path: "b.key", source: .workingTree))
        let untracked = file("draft.key", change: .untracked, old: .index, new: .workingTree)
        #expect(untracked.oldItem == nil)
    }

    @Test func aFileIsInTheOutermostPackageAmongItsFolders() {
        #expect(DocumentPackages.package(containing: "Boards/Coil.horizontal/board.json", isPackage: isBoard)
            == "Boards/Coil.horizontal")
        #expect(DocumentPackages.package(containing: "Coil.horizontal/pool/parts/a.horizontal/x", isPackage: isBoard)
            == "Coil.horizontal")
        // The file's own name is not a folder.
        #expect(DocumentPackages.package(containing: "Boards/Coil.horizontal", isPackage: isBoard) == nil)
        #expect(DocumentPackages.package(containing: "Sources/main.swift", isPackage: isBoard) == nil)
    }

    @Test func theSystemsOwnPackageTypesAreKnown() {
        #expect(DocumentPackages.isPackage(extension: "rtfd"))
        #expect(DocumentPackages.isPackage(extension: "APP"))
        #expect(!DocumentPackages.isPackage(extension: "json"))
        #expect(!DocumentPackages.isPackage(extension: "qltestunknown"))
        #expect(!DocumentPackages.isPackage(extension: ""))
        #expect(DocumentPackages.package(containing: "Notes/Letter.rtfd/TXT.rtf") == "Notes/Letter.rtfd")
    }

    @Test func aPackagesFilesShowItsPictureAboveTheFirst() throws {
        let files = [
            file("README.md"),
            file("Coil.horizontal/board.json"),
            file("Coil.horizontal/schematic.json"),
            file("Tiger.horizontal/board.json", change: .added),
            file("Tiger.horizontal/pool/part.json", change: .added)
        ]
        let packages = DocumentPackages.changes(in: files, repositoryName: "designs", isPackage: isBoard)
        #expect(Set(packages.keys) == ["Coil.horizontal/board.json", "Tiger.horizontal/board.json"])
        let coil = try #require(packages["Coil.horizontal/board.json"])
        #expect(coil.path == "Coil.horizontal")
        #expect(coil.name == "Coil.horizontal")
        #expect(coil.change == .modified)
        #expect(coil.files == ["Coil.horizontal/board.json", "Coil.horizontal/schematic.json"])
        #expect(coil.oldItem == PreviewItem(path: "Coil.horizontal", source: .commit(oldCommit)))
        #expect(coil.newItem == PreviewItem(path: "Coil.horizontal", source: .commit(newCommit)))
        let tiger = try #require(packages["Tiger.horizontal/board.json"])
        #expect(tiger.change == .added)
        #expect(tiger.oldItem == nil)
    }

    @Test func aDeletedOrRenamedPackageKeepsItsOldPlace() throws {
        let deleted = DocumentPackages.changes(
            in: [file("Old.horizontal/board.json", change: .deleted)], repositoryName: "r", isPackage: isBoard
        )
        let gone = try #require(deleted["Old.horizontal/board.json"])
        #expect(gone.change == .deleted)
        #expect(gone.newItem == nil)
        #expect(gone.oldItem == PreviewItem(path: "Old.horizontal", source: .commit(oldCommit)))

        let renamed = DocumentPackages.changes(
            in: [file("New.horizontal/board.json", oldPath: "Old.horizontal/board.json", change: .renamed)],
            repositoryName: "r", isPackage: isBoard
        )
        let moved = try #require(renamed["New.horizontal/board.json"])
        #expect(moved.change == .renamed)
        #expect(moved.oldItem == PreviewItem(path: "Old.horizontal", source: .commit(oldCommit)))
        #expect(moved.newItem == PreviewItem(path: "New.horizontal", source: .commit(newCommit)))
    }

    @Test func aRepositoryThatIsAPackageIsOnePictureOfItAll() throws {
        let files = [file("board.json"), file("pool/part.json")]
        let packages = DocumentPackages.changes(in: files, repositoryName: "x-band-tx.horizontal", isPackage: isBoard)
        #expect(Set(packages.keys) == ["board.json"])
        let root = try #require(packages["board.json"])
        #expect(root.path == "")
        #expect(root.name == "x-band-tx.horizontal")
        #expect(root.files.count == 2)
        #expect(DocumentPackages.changes(in: files, repositoryName: "designs", isPackage: isBoard).isEmpty)
    }

    @Test func copiesKeepTheFilesOwnNameAndExtension() {
        #expect(PreviewFiles.fileName(for: "Boards/Coil.horizontal") == "Coil.horizontal")
        #expect(PreviewFiles.fileName(for: "Talks/Launch.key") == "Launch.key")
        #expect(PreviewFiles.fileName(for: "", repositoryName: "x-band-tx.horizontal") == "x-band-tx.horizontal")
        #expect(PreviewFiles.fileName(for: "odd/a:b.pdf") == "a-b.pdf")
        #expect(PreviewFiles.fileName(for: "..") == "file")
    }

    @Test func copiesFromElsewhereSayWhereFrom() {
        let hash = newCommit.abbreviated()
        #expect(PreviewFiles.exportName(for: "Boards/Coil.horizontal", source: .workingTree) == "Coil.horizontal")
        #expect(PreviewFiles.exportName(for: "Boards/Coil.horizontal", source: .commit(newCommit))
            == "Coil-\(hash).horizontal")
        #expect(PreviewFiles.exportName(for: "Talks/Launch.key", source: .index) == "Launch-staged.key")
        #expect(PreviewFiles.exportName(for: "", source: .commit(newCommit), repositoryName: "tx.horizontal")
            == "tx-\(hash).horizontal")
        #expect(FileDrag.fileName(for: "Makefile", suffix: "staged") == "Makefile-staged")
        #expect(DragFiles.safeName("a/b:c") == "a-b-c")
    }

    @Test func aPreviewsFolderGoesWithIt() throws {
        var folder: PreviewFolder? = try PreviewFolder()
        let url = try #require(folder?.url)
        let copy = try #require(folder?.location(of: "Coil.horizontal", in: "Before"))
        #expect(copy.lastPathComponent == "Coil.horizontal")
        #expect(copy.deletingLastPathComponent().lastPathComponent == "Before")
        #expect(FileManager.default.fileExists(atPath: url.path))
        folder = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Quick Look itself: a picture of what an RTFD package holds, but none
    /// of a plain folder, which has only its icon. Left to a Mac with a
    /// session: build machines may run without Quick Look's service.
    @Test(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil))
    func quickLookDrawsContentNotIcons() async throws {
        let folder = try PreviewFolder()
        let letter = folder.location(of: "Letter.rtfd", in: "Before")
        try FileManager.default.createDirectory(at: letter, withIntermediateDirectories: true)
        try Data(#"{\rtf1\ansi Hello {\b world}}"#.utf8).write(to: letter.appending(path: "TXT.rtf"))
        let plain = folder.location(of: "Plain", in: "After")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: plain.appending(path: "a.txt"))

        let size = CGSize(width: 200, height: 200)
        let picture = await QuickLookThumbnail.make(for: letter, size: size, scale: 1)
        #expect(picture != nil)
        #expect(await QuickLookThumbnail.make(for: plain, size: size, scale: 1) == nil)
    }
}
