import Foundation
import GitKit
import Testing
@testable import WyeUI

/// Selecting a branch or tag in the sidebar selects the commit it points at
/// in the full history, rather than listing that history alone.
@MainActor
@Suite struct ReferenceSelectionTests {
    /// A repository with `main` one commit ahead of `topic`.
    @MainActor
    private struct Scratch {
        let folder: URL
        let repository: Repository
        let model: RepositoryModel
        let first: OID
        let second: OID
        let topic: String

        init() async throws {
            folder = FileManager.default.temporaryDirectory
                .appending(path: "WyeUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
            repository = try Repository.create(at: folder)
            let identity = GitIdentity(name: "Test Author", email: "author@example.com")
            // The repository's own, too: an annotated tag's tagger is read
            // from configuration, and a machine like CI's has no global one.
            try await repository.setLocalIdentity(identity)
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
            await model.refresh()
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func branchesAndTagsListEveryCommit() {
        #expect(SidebarItem.branch("refs/heads/topic").historyScope == .allReferences)
        #expect(SidebarItem.remoteBranch("refs/remotes/origin/main").historyScope == .allReferences)
        #expect(SidebarItem.tag("refs/tags/v1").historyScope == .allReferences)
        #expect(SidebarItem.branch("refs/heads/topic").isReference)
        #expect(SidebarItem.remoteBranch("refs/remotes/origin/main").isReference)
        #expect(SidebarItem.tag("refs/tags/v1").isReference)
        #expect(!SidebarItem.history.isReference)
        #expect(!SidebarItem.workingCopy.isReference)
    }

    @Test func aBranchSelectsItsCommitAmongAllOthers() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let model = scratch.model
        #expect(model.history.loadedCommits.map(\.id) == [scratch.second, scratch.first])

        model.selection = .branch(scratch.topic)
        // At once, so Back and Forward see a single step.
        #expect(model.history.selection == scratch.first)
        await model.revealSelectedReference()
        #expect(model.referenceToReveal == nil)
        #expect(model.history.selection == scratch.first)
        #expect(model.history.scope == .allReferences)
        #expect(model.history.loadedCommits.map(\.id) == [scratch.second, scratch.first])
    }

    @Test func aTagSelectsTheCommitItLeadsTo() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let model = scratch.model
        // Annotated, so the reference names a tag object rather than the commit.
        let tag = try await scratch.repository.createTag(named: "v1", at: scratch.first, message: "Version one")
        await model.refresh()

        model.selection = .tag(tag)
        #expect(model.history.selection == scratch.first)
        await model.revealSelectedReference()
        #expect(model.referenceToReveal == nil)
        #expect(model.history.selection == scratch.first)
        #expect(model.history.loadedCommits.map(\.id) == [scratch.second, scratch.first])
    }

    @Test func aBranchListedOnlyByALaterRefreshIsSelectedThen() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let model = scratch.model

        // As an operation selects the branch it made, before the refresh.
        model.selection = .branch("refs/heads/later")
        #expect(model.commitToReveal == nil)
        await model.revealSelectedReference()
        #expect(model.history.selection == nil)

        _ = try await scratch.repository.createBranch(named: "later", at: scratch.first)
        await model.refresh()
        #expect(model.commitToReveal == scratch.first)
        await model.revealSelectedReference()
        #expect(model.history.selection == scratch.first)
        #expect(model.referenceToReveal == nil)
    }

    @Test func goingBackToABranchRestoresTheCommitSelectedThere() async throws {
        let scratch = try await Scratch()
        defer { scratch.remove() }
        let model = scratch.model
        let navigation = RepositoryNavigation()

        model.selection = .branch(scratch.topic)
        navigation.record(model.location)
        await model.revealSelectedReference()
        // A commit other than the branch's, chosen in the list.
        model.history.selection = scratch.second
        navigation.record(model.location)
        model.selection = .history
        navigation.record(model.location)

        await navigation.goBack(in: model)
        #expect(model.selection == .branch(scratch.topic))
        // What the window's task runs next must leave it be.
        await model.revealSelectedReference()
        #expect(model.history.selection == scratch.second)
    }
}
