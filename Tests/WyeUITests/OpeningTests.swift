import Foundation
import GitKit
import Testing
@testable import WyeUI

/// What a window opens with, read ahead of the window, and what the history
/// is read again for.
@MainActor
@Suite struct OpeningTests {
    /// A repository with a line of commits.
    @MainActor
    private struct Scratch {
        let folder: URL
        let repository: Repository
        private let identity = GitIdentity(name: "Test Author", email: "author@example.com")

        init(commits: Int) async throws {
            folder = FileManager.default.temporaryDirectory
                .appending(path: "WyeUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
            repository = try Repository.create(at: folder)
            // The repository's own: a stash's author is read from configuration.
            try await repository.setLocalIdentity(identity)
            for number in 1...commits {
                try await commit("\(number)")
            }
        }

        @discardableResult
        func commit(_ text: String) async throws -> OID {
            try write(text)
            try await repository.stage(["a.txt"])
            return try await repository.commit(message: "Commit \(text)", as: identity)
        }

        func write(_ text: String, to name: String = "a.txt") throws {
            try Data("\(text)\n".utf8).write(to: folder.appending(path: name))
        }

        func model() throws -> RepositoryModel {
            try RepositoryModel(
                bookmark: RepositoryBookmark(name: "Scratch", location: .documents("Scratch")),
                access: RepositoryAccess(url: folder, scoped: false)
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func anOpeningWindowHasItsReferencesAndHistoryBeforeItsWorkingCopy() async throws {
        let scratch = try await Scratch(commits: 3)
        defer { scratch.remove() }
        try scratch.write("new", to: "untracked.txt")
        let model = try scratch.model()

        model.beginLoading()
        await model.finishLoading()
        let head = try #require(model.snapshot?.head.target)
        #expect(model.history.loadedCommits.map(\.summary) == ["Commit 3", "Commit 2", "Commit 1"])
        #expect(model.refLabels[head]?.map(\.kind) == [.branch])
        // Not read yet: that waits for the refresh.
        #expect(model.workingCopy.entries.isEmpty)
        #expect(model.revision == 0)

        // Which reads the rest, and not the history again.
        let generation = model.history.generation
        await model.refresh()
        #expect(model.workingCopy.entries.map(\.path) == ["untracked.txt"])
        #expect(model.history.generation == generation)
        #expect(model.history.loadedCommits.map(\.summary) == ["Commit 3", "Commit 2", "Commit 1"])
    }

    @Test func aWindowOpenedWithoutReadingAheadReadsEverythingInItsRefresh() async throws {
        let scratch = try await Scratch(commits: 2)
        defer { scratch.remove() }
        let model = try scratch.model()

        await model.finishLoading()
        #expect(model.snapshot == nil)
        await model.refresh()
        #expect(model.snapshot != nil)
        #expect(model.history.loadedCommits.map(\.summary) == ["Commit 2", "Commit 1"])
        #expect(model.history.commitCount == 2)
    }

    @Test func theHistoryIsReadAgainOnlyWhenAReferenceMoves() async throws {
        let scratch = try await Scratch(commits: 2)
        defer { scratch.remove() }
        let model = try scratch.model()
        await model.refresh()
        let generation = model.history.generation

        // A change in the working copy, and a stash of it, move no reference.
        try scratch.write("edited")
        await model.refresh()
        #expect(model.workingCopy.entries.map(\.path) == ["a.txt"])
        _ = try await scratch.repository.saveStash()
        await model.refresh()
        #expect(model.snapshot?.stashes.count == 1)
        #expect(model.history.generation == generation)

        try await scratch.commit("3")
        await model.refresh()
        #expect(model.history.generation > generation)
        #expect(model.history.loadedCommits.map(\.summary) == ["Commit 3", "Commit 2", "Commit 1"])
        #expect(model.history.commitCount == 3)
    }

    @Test func aHistoryOpensWithOnePageAndIsAsLongWhenReadAgain() async throws {
        let count = HistoryModel.firstPageSize + 10
        let scratch = try await Scratch(commits: count)
        defer { scratch.remove() }
        let model = try scratch.model()
        await model.refresh()
        #expect(Array(model.history.loadedCommits).count == HistoryModel.firstPageSize)
        #expect(!model.history.isComplete)
        #expect(model.history.commitCount == count)

        await model.history.loadMore()
        #expect(Array(model.history.loadedCommits).count == count)
        #expect(model.history.isComplete)

        // Read again for a new commit, the list does not shorten to a page.
        try await scratch.commit("more")
        await model.refresh()
        let commits = Array(model.history.loadedCommits)
        #expect(commits.count == count)
        #expect(commits.first?.summary == "Commit more")
    }
}
