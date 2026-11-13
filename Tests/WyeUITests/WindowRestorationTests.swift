import Foundation
import GitKit
import Testing
@testable import WyeUI

/// A window reopens to the repository, sidebar item and commit it showed.
@MainActor
@Suite struct WindowRestorationTests {
    /// A repository with `main` one commit ahead of `topic`, opened in a
    /// model that has not read it yet, as a window opening has.
    @MainActor
    private struct Scratch {
        let folder: URL
        let model: RepositoryModel
        let first: OID
        let second: OID
        let topic: String

        init() async throws {
            folder = FileManager.default.temporaryDirectory
                .appending(path: "WyeUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
            let repository = try Repository.create(at: folder)
            let identity = GitIdentity(name: "Test Author", email: "author@example.com")
            try Data("one\n".utf8).write(to: folder.appending(path: "a.txt"))
            try await repository.stage(["a.txt"])
            first = try await repository.commit(message: "One", as: identity)
            topic = try await repository.createBranch(named: "topic")
            try Data("two\n".utf8).write(to: folder.appending(path: "a.txt"))
            try await repository.stage(["a.txt"])
            second = try await repository.commit(message: "Two", as: identity)

            model = try RepositoryModel(
                bookmark: RepositoryBookmark(name: "Scratch", location: .documents("Scratch")),
                access: RepositoryAccess(url: folder, scoped: false)
            )
        }

        /// What a repository window does as it opens: read the repository,
        /// show the history, then select what it should.
        func open() async {
            await model.refresh()
            if let scope = model.selection?.historyScope {
                await model.history.show(scope)
            }
            await model.revealSelectedReference()
            await model.restoreSelectedCommit()
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func aSavedWindowSurvivesBeingKept() throws {
        let saved = SavedWindow(repository: UUID(), selection: .branch("refs/heads/topic"),
                                commit: "1111111111111111111111111111111111111111")
        #expect(SavedWindow(encoded: saved.encoded) == saved)
        #expect(SavedWindow(encoded: SavedWindow(repository: UUID(), selection: .stashes).encoded)?.selection == .stashes)
        #expect(SavedWindow(encoded: nil) == nil)
        #expect(SavedWindow(encoded: "not a window") == nil)
    }

    @Test func aReopenedWindowSelectsTheCommitItHad() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let model = scratch.model
        // On the topic branch, with the newer commit selected rather than
        // the one the branch points at.
        model.restore(SavedWindow(repository: model.id, selection: .branch(scratch.topic), commit: scratch.second.hex))
        #expect(model.selection == .branch(scratch.topic))
        #expect(SavedWindow(model).commit == scratch.second.hex)

        await scratch.open()
        #expect(model.selection == .branch(scratch.topic))
        #expect(model.history.selection == scratch.second)
        #expect(model.commitToRestore == nil)
    }

    @Test func aBranchSelectsItsCommitWhenNoneWasSaved() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let model = scratch.model
        model.restore(SavedWindow(repository: model.id, selection: .branch(scratch.topic)))
        await scratch.open()
        #expect(model.history.selection == scratch.first)
    }

    @Test func aCommitWaitsForTheHistoryToBeShown() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let model = scratch.model
        model.restore(SavedWindow(repository: model.id, selection: .stashes, commit: scratch.first.hex))
        await scratch.open()
        #expect(model.selection == .stashes)
        #expect(model.commitToRestore == scratch.first)

        model.selection = .history
        await scratch.open()
        #expect(model.history.selection == scratch.first)
        #expect(model.commitToRestore == nil)
    }

    @Test func aBranchThatIsGoneGivesTheHistory() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let model = scratch.model
        model.restore(SavedWindow(repository: model.id, selection: .branch("refs/heads/gone")))
        await scratch.open()
        #expect(model.selection == .history)
    }

    @Test func anotherRepositorysWindowIsLeftAlone() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let model = scratch.model
        model.restore(SavedWindow(repository: UUID(), selection: .reflog, commit: scratch.first.hex))
        #expect(model.selection == .history)
        #expect(model.commitToRestore == nil)
    }
}
