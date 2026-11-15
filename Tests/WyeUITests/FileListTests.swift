import Foundation
import GitKit
import Testing
@testable import WyeUI

@Suite struct FileListTests {
    private func entry(_ path: String, staged: FileChange? = nil, unstaged: FileChange? = .modified) -> StatusEntry {
        StatusEntry(path: path, originalPath: nil, staged: staged, unstaged: unstaged)
    }

    private var entries: [StatusEntry] {
        [
            entry("Sources/App/main.swift"),
            entry("README.md", staged: .modified, unstaged: nil),
            entry("Sources/App/View.swift", unstaged: .untracked),
            entry("Sources/Kit/Engine/Core.swift", staged: .added, unstaged: nil),
            entry("docs/b10.md", unstaged: .deleted),
            entry("docs/b9.md"),
            entry("Package.swift", unstaged: .conflicted)
        ]
    }

    @Test func sortsByNameAndBySideStatus() {
        #expect(FileList.sorted(entries, by: .name, side: .unstaged).map(\.path) == [
            "docs/b9.md", "docs/b10.md", "Sources/Kit/Engine/Core.swift", "Sources/App/main.swift",
            "Package.swift", "README.md", "Sources/App/View.swift"
        ])
        #expect(FileList.sorted(entries, by: .status, side: .unstaged).map(\.path) == [
            "Package.swift", "Sources/Kit/Engine/Core.swift", "docs/b9.md", "README.md",
            "Sources/App/main.swift", "docs/b10.md", "Sources/App/View.swift"
        ])
        // A file goes by the change on the side asked for.
        let both = [
            entry("a.txt", staged: .modified, unstaged: .deleted),
            entry("b.txt", staged: .deleted, unstaged: .modified)
        ]
        #expect(FileList.sorted(both, by: .status, side: .staged).map(\.path) == ["a.txt", "b.txt"])
        #expect(FileList.sorted(both, by: .status, side: .unstaged).map(\.path) == ["b.txt", "a.txt"])
    }

    @Test func filtersByEveryWordOfThePath() {
        #expect(FileList.filtered(entries, by: "").count == entries.count)
        #expect(FileList.filtered(entries, by: "  ").count == entries.count)
        #expect(FileList.filtered(entries, by: "swift").map(\.path) == [
            "Sources/App/main.swift", "Sources/App/View.swift", "Sources/Kit/Engine/Core.swift", "Package.swift"
        ])
        #expect(FileList.filtered(entries, by: "app VIEW").map(\.path) == ["Sources/App/View.swift"])
        #expect(FileList.filtered(entries, by: "nothing").isEmpty)
        let renamed = StatusEntry(path: "new.txt", originalPath: "old.txt", staged: .renamed, unstaged: nil)
        #expect(FileList.filtered([renamed], by: "old").count == 1)
    }

    @Test func buildsATreeWithFoldersFirstAndChainsJoined() {
        let tree = FileList.tree(entries, sort: .name, side: .unstaged)
        #expect(tree.map(\.id) == ["docs/", "Sources/", "Package.swift", "README.md"])
        let sources = tree[1]
        #expect(sources.name == "Sources")
        #expect(sources.entries.count == 3)
        // Kit holds only Engine, so they show as one folder.
        #expect(sources.children.map(\.name) == ["App", "Kit/Engine", ])
        #expect(sources.children[1].id == "Sources/Kit/Engine/")
        #expect(sources.children[1].path == "Sources/Kit/Engine")
        #expect(sources.children[1].children.map(\.id) == ["Sources/Kit/Engine/Core.swift"])
        #expect(sources.children[0].children.map(\.name) == ["main.swift", "View.swift"])
        #expect(tree[0].children.map(\.name) == ["b9.md", "b10.md"])
    }

    @Test func sortsFilesInAFolderByStatus() {
        let tree = FileList.tree(entries, sort: .status, side: .unstaged)
        #expect(tree.map(\.id) == ["docs/", "Sources/", "Package.swift", "README.md"])
        #expect(tree[0].children.map(\.name) == ["b9.md", "b10.md"])
        #expect(tree[1].children[0].children.map(\.name) == ["main.swift", "View.swift"])
    }

    // MARK: Sections

    /// Changes with no conflict among them, as the sections are given.
    private var changes: [StatusEntry] {
        [
            entry("Sources/App/main.swift"),
            entry("README.md", staged: .modified, unstaged: nil),
            entry("Sources/App/View.swift", staged: .added, unstaged: .modified),
            entry("Sources/Kit/Engine/Core.swift", staged: .added, unstaged: nil),
            entry("docs/b9.md")
        ]
    }

    @Test func listsAFileUnderEachSideItHasChangesOn() {
        let sections = FileList.sections(changes, sort: .name)
        #expect(sections.staged.map(\.node.id) == [
            "Sources/", "Sources/App/", "Sources/App/View.swift", "Sources/Kit/Engine/",
            "Sources/Kit/Engine/Core.swift", "README.md"
        ])
        #expect(sections.staged.map(\.depth) == [0, 1, 2, 1, 2, 0])
        #expect(sections.unstaged.map(\.node.id) == [
            "docs/", "docs/b9.md", "Sources/App/", "Sources/App/main.swift", "Sources/App/View.swift"
        ])
        #expect(sections.unstaged.map(\.depth) == [0, 1, 0, 1, 1])
        #expect(sections.staged.allSatisfy { $0.side == .staged })
        #expect(sections.unstaged.allSatisfy { $0.side == .unstaged })
        #expect(sections.fileCount(on: .staged) == 3)
        #expect(sections.fileCount(on: .unstaged) == 3)
        // A folder under Staged holds only what is staged in it.
        #expect(sections.staged[1].node.entries.map(\.path) == ["Sources/App/View.swift"])
    }

    @Test func keepsARowsIdentityWhenAllOfItChangesSides() {
        let before = FileList.sections(changes, sort: .name)
        // A file or a folder on one side only goes by its path alone.
        #expect(before.unstaged.map(\.id) == [
            .item("docs/"), .item("docs/b9.md"), .item("Sources/App/"), .item("Sources/App/main.swift"),
            .item("Sources/App/View.swift")
        ])
        // On both sides, the row under Staged is the other one.
        #expect(before.staged.map(\.id) == [
            .stagedPart("Sources/"), .stagedPart("Sources/App/"), .stagedPart("Sources/App/View.swift"),
            .item("Sources/Kit/Engine/"), .item("Sources/Kit/Engine/Core.swift"), .item("README.md")
        ])
        // Staging all of docs moves its rows, which keep their identity.
        let staged = changes.map { entry in
            entry.path.hasPrefix("docs/") ? self.entry(entry.path, staged: .modified, unstaged: nil) : entry
        }
        let after = FileList.sections(staged, sort: .name)
        #expect(after.staged.prefix(2).map(\.id) == [.item("docs/"), .item("docs/b9.md")])
        #expect(!after.unstaged.contains { $0.node.id.hasPrefix("docs/") })
        // No row is listed twice.
        #expect(Set((after.staged + after.unstaged).map(\.id)).count == after.staged.count + after.unstaged.count)
    }

    @Test func keepsIdentitiesWhileFiltering() {
        // The filter leaves out the unstaged file that is in Sources/App,
        // but the folder's row under Staged stays the row it was.
        let sections = FileList.sections(changes, matching: "view", sort: .name)
        #expect(sections.unstaged.map(\.id) == [.item("Sources/App/"), .item("Sources/App/View.swift")])
        #expect(sections.staged.map(\.id) == [.stagedPart("Sources/App/"), .stagedPart("Sources/App/View.swift")])
        let core = FileList.sections(changes, matching: "core", sort: .name)
        #expect(core.unstaged.isEmpty)
        #expect(core.staged.map(\.id) == [.item("Sources/Kit/Engine/"), .item("Sources/Kit/Engine/Core.swift")])
        #expect(FileList.sections(changes, matching: "nothing", sort: .name).isEmpty)
    }

    @Test func leavesOutWhatACollapsedFolderHolds() {
        // Folded under Staged only: the same folder under Unstaged stays open.
        let folded = FileList.sections(changes, sort: .name, collapsed: [.stagedPart("Sources/"), .item("docs/")])
        #expect(folded.staged.map(\.node.id) == ["Sources/", "README.md"])
        #expect(folded.unstaged.map(\.node.id) == [
            "docs/", "Sources/App/", "Sources/App/main.swift", "Sources/App/View.swift"
        ])
        // The count is of the files, shown or not.
        #expect(folded.fileCount(on: .staged) == 3)
    }

    @Test func stagesTheSelectedRowsOrUnstagesThem() {
        let sections = FileList.sections(changes, sort: .name)
        func action(_ rows: Set<ChangeRowID>, in sections: ChangeSections) -> StagingAction? {
            SelectedChanges(rows, in: sections).action
        }
        #expect(action([], in: sections) == nil)
        #expect(action([.item("Sources/App/main.swift")], in: sections)
            == StagingAction(from: .unstaged, paths: ["Sources/App/main.swift"]))
        // A folder stands for the files under it on its side, each once.
        #expect(action([.item("Sources/App/"), .item("Sources/App/View.swift")], in: sections)
            == StagingAction(from: .unstaged, paths: ["Sources/App/main.swift", "Sources/App/View.swift"]))
        #expect(action([.stagedPart("Sources/")], in: sections)
            == StagingAction(from: .staged, paths: ["Sources/App/View.swift", "Sources/Kit/Engine/Core.swift"]))
        // With rows selected on both sides, the unstaged ones are staged.
        #expect(action([.item("README.md"), .item("docs/b9.md")], in: sections)
            == StagingAction(from: .unstaged, paths: ["docs/b9.md"]))
        #expect(action([.item("README.md")], in: sections) == StagingAction(from: .staged, paths: ["README.md"]))
        // A row that is not in the list, such as one in a folded folder, is left alone.
        let folded = FileList.sections(changes, sort: .name, collapsed: [.item("docs/")])
        #expect(action([.item("docs/b9.md")], in: folded) == nil)
    }

    @Test func aRowsMenuActsOnTheRowsSelectedWithIt() {
        let sections = FileList.sections(changes, sort: .name)
        let main = try! #require(sections.unstaged.first { $0.id == .item("Sources/App/main.swift") })
        let docs = try! #require(sections.unstaged.first { $0.id == .item("docs/") })
        // Alone, or not among the selected rows: the row itself.
        #expect(SelectedChanges([main.id], in: sections).paths(for: main) == ["Sources/App/main.swift"])
        #expect(SelectedChanges([.item("README.md"), main.id], in: sections).paths(for: docs) == ["docs/b9.md"])
        // One of several: those of its section.
        let several = SelectedChanges([main.id, docs.id, .item("README.md")], in: sections)
        #expect(several.includes(main))
        #expect(several.paths(for: main) == ["docs/b9.md", "Sources/App/main.swift"])
    }

    // MARK: Selection

    @Test func selectsTheRowOfTheFileShown() {
        var state = WorkingCopyState(entries: changes)
        #expect(state.listSelection.isEmpty)
        // A file selected from elsewhere has its one row selected.
        state.selection = "README.md"
        #expect(state.listSelection == [.item("README.md")])
        // Selecting rows shows a file among them, and keeps the one shown.
        state.listSelection = [.item("docs/b9.md")]
        #expect(state.selection == "docs/b9.md")
        state.listSelection = [.item("docs/b9.md"), .stagedPart("Sources/App/View.swift")]
        #expect(state.selection == "docs/b9.md")
        #expect(state.selectedPaths == ["docs/b9.md", "Sources/App/View.swift"])
        state.listSelection = [.stagedPart("Sources/App/View.swift")]
        #expect(state.selection == "Sources/App/View.swift")
        // A folder shows no file, and stays selected.
        state.listSelection = [.item("docs/")]
        #expect(state.selection == nil)
        #expect(state.listSelection == [.item("docs/")])
        #expect(state.selectedPaths.isEmpty)
    }

    @Test func keepsAFileSelectedOnceItsUnstagedChangesAreGone() {
        var state = WorkingCopyState(entries: changes)
        state.listSelection = [.stagedPart("Sources/App/View.swift")]
        // The rest of the file is staged: its row under Staged is its only row.
        state.entries = changes.map { entry in
            entry.path == "Sources/App/View.swift" ? self.entry(entry.path, staged: .added, unstaged: nil) : entry
        }
        #expect(state.listSelection == [.item("Sources/App/View.swift")])
    }
}
