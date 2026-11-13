import Foundation
import GitKit
import Testing
@testable import WyeUI

/// The interactive rebase sheet's plan: moving rows, the messages it asks
/// for, and the steps it hands the engine.
@MainActor
@Suite struct InteractiveRebaseDraftTests {
    private static func id(_ number: Int) -> OID {
        OID(hex: String(repeating: String(number), count: 40))!
    }

    private static func candidate(_ number: Int, _ message: String) -> RebaseCandidate {
        let signature = Signature(name: "A", email: "a@example.com", date: .now)
        let summary = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let commit = Commit(id: id(number), parentIDs: [], treeID: id(9), author: signature, committer: signature,
                            summary: summary, body: "")
        return RebaseCandidate(commit: commit, message: message + "\n")
    }

    private func draft(autosquashed: [RebaseStep]? = nil) -> InteractiveRebaseDraft {
        let candidates = [Self.candidate(1, "One"), Self.candidate(2, "Two\n\nBody two."), Self.candidate(3, "Three")]
        return InteractiveRebaseDraft(todo: RebaseTodo(onto: Self.id(8), candidates: candidates, skippedMerges: 0,
                                                       autosquashed: autosquashed))
    }

    @Test func movingRowsReordersTheSteps() {
        let draft = draft()
        #expect(draft.isUnchanged)
        #expect(!draft.canMove(Self.id(1), by: -1))
        draft.move(Self.id(1), by: 1)
        #expect(draft.steps.map(\.commit) == [Self.id(2), Self.id(1), Self.id(3)])
        draft.move(fromOffsets: [2], toOffset: 0)
        #expect(draft.steps.map(\.commit) == [Self.id(3), Self.id(2), Self.id(1)])
        #expect(!draft.isUnchanged)
    }

    /// Moving the commits onto another branch changes the branch even with
    /// every commit picked in order.
    @Test func aPlanOntoANewBaseIsNeverUnchanged() {
        let candidates = [Self.candidate(1, "One"), Self.candidate(2, "Two")]
        let draft = InteractiveRebaseDraft(todo: RebaseTodo(
            onto: Self.id(8), candidates: candidates, skippedMerges: 0, autosquashed: nil, changesBase: true
        ))
        #expect(!draft.isUnchanged)
    }

    @Test func aSquashOffersGitsCombinedMessageAndKeepsAnEditedOne() throws {
        let draft = draft()
        draft.setAction(.squash, for: Self.id(2))
        draft.setAction(.fixup, for: Self.id(3))
        let squash = try #require(draft.rows.first { $0.id == Self.id(2) })
        #expect(draft.asksForMessage(squash))
        #expect(draft.message(for: Self.id(2)) == "One\n\nTwo\n\nBody two.")
        // Without a typed message the engine makes git's own.
        #expect(draft.steps.allSatisfy { $0.message == nil })

        draft.setMessage("One and two", for: Self.id(2))
        let steps = draft.steps
        #expect(steps.map(\.action) == [.pick, .squash, .fixup])
        // The run's message rides on its last step.
        #expect(steps[1].message == nil)
        #expect(steps[2].message == "One and two")
    }

    @Test func aRewordCarriesItsMessage() {
        let draft = draft()
        draft.setAction(.reword, for: Self.id(1))
        #expect(draft.message(for: Self.id(1)) == "One")
        draft.setMessage("  ", for: Self.id(1))
        #expect(draft.problem != nil)
        draft.setMessage("Better one", for: Self.id(1))
        #expect(draft.problem == nil)
        #expect(draft.steps[0] == RebaseStep(commit: Self.id(1), action: .reword, message: "Better one"))
        // Back to a pick, the message is not used.
        draft.setAction(.pick, for: Self.id(1))
        #expect(draft.steps[0].message == nil)
    }

    @Test func aSquashFirstIsAProblem() {
        let draft = draft()
        draft.setAction(.drop, for: Self.id(1))
        draft.setAction(.fixup, for: Self.id(2))
        #expect(draft.problem?.contains("“Two”") == true)
    }

    @Test func autosquashIsOnWhenItChangesSomethingAndCanBeTurnedOff() {
        let autosquashed = [
            RebaseStep(commit: Self.id(1)), RebaseStep(commit: Self.id(3), action: .fixup), RebaseStep(commit: Self.id(2))
        ]
        let draft = draft(autosquashed: autosquashed)
        #expect(draft.autosquash)
        #expect(draft.steps == autosquashed)
        draft.autosquash = false
        #expect(draft.steps.map(\.commit) == [Self.id(1), Self.id(2), Self.id(3)])
        #expect(draft.steps.allSatisfy { $0.action == .pick })
        #expect(!self.draft().autosquash)
    }
}
