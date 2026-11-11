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

    @Test func sortsByPathNameAndStatus() {
        #expect(FileList.sorted(entries, by: .path).map(\.path) == [
            "docs/b9.md", "docs/b10.md", "Package.swift", "README.md",
            "Sources/App/main.swift", "Sources/App/View.swift", "Sources/Kit/Engine/Core.swift"
        ])
        #expect(FileList.sorted(entries, by: .name).map(\.path) == [
            "docs/b9.md", "docs/b10.md", "Sources/Kit/Engine/Core.swift", "Sources/App/main.swift",
            "Package.swift", "README.md", "Sources/App/View.swift"
        ])
        #expect(FileList.sorted(entries, by: .status).map(\.path) == [
            "Package.swift", "Sources/Kit/Engine/Core.swift", "docs/b9.md", "README.md",
            "Sources/App/main.swift", "docs/b10.md", "Sources/App/View.swift"
        ])
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
        let tree = FileList.tree(entries, sort: .path)
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
        let tree = FileList.tree(entries, sort: .status)
        #expect(tree.map(\.id) == ["docs/", "Sources/", "Package.swift", "README.md"])
        #expect(tree[0].children.map(\.name) == ["b9.md", "b10.md"])
        #expect(tree[1].children[0].children.map(\.name) == ["main.swift", "View.swift"])
    }

    @Test func leavesOutWhatACollapsedFolderHolds() {
        let tree = FileList.tree(entries, sort: .path)
        let all = FileList.rows(tree, collapsed: [])
        #expect(all.map(\.id) == [
            "docs/", "docs/b9.md", "docs/b10.md", "Sources/", "Sources/App/", "Sources/App/main.swift",
            "Sources/App/View.swift", "Sources/Kit/Engine/", "Sources/Kit/Engine/Core.swift",
            "Package.swift", "README.md"
        ])
        #expect(all.map(\.depth) == [0, 1, 1, 0, 1, 2, 2, 1, 2, 0, 0])
        let folded = FileList.rows(tree, collapsed: ["Sources/", "docs/b9.md"])
        #expect(folded.map(\.id) == ["docs/", "docs/b9.md", "docs/b10.md", "Sources/", "Package.swift", "README.md"])
    }

    @Test func tellsHowMuchOfAFolderIsStaged() {
        #expect(StagingState([entry("a", staged: nil, unstaged: .modified)]) == .unstaged)
        #expect(StagingState([entry("a", staged: .modified, unstaged: nil)]) == .staged)
        #expect(StagingState([entry("a", staged: .modified, unstaged: .modified)]) == .partlyStaged)
        #expect(StagingState([
            entry("a", staged: .modified, unstaged: nil), entry("b", staged: nil, unstaged: .modified)
        ]) == .partlyStaged)
        #expect(StagingState([]) == .unstaged)
    }
}
