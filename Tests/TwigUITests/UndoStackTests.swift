import Foundation
import GitKit
import Testing
@testable import TwigUI

@MainActor
@Suite struct UndoStackTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "TwigUITests-\(UUID().uuidString)")
    var storage: URL { folder.appending(path: "Undo/history.json") }

    /// Records of creating tags `names` in a new repository, in order.
    private func tagRecords(_ names: [String]) async throws -> [UndoFinish] {
        let repository = try Repository.create(at: folder.appending(path: "repository"))
        try "[user]\n\tname = Test\n\temail = test@example.com\n".write(
            to: folder.appending(path: "repository/.git/config"), atomically: true, encoding: .utf8
        )
        try "one\n".write(to: folder.appending(path: "repository/a.txt"), atomically: true, encoding: .utf8)
        try await repository.stage(["a.txt"])
        let commit = try await repository.commit(message: "One")
        var finishes: [UndoFinish] = []
        for name in names {
            let start = await repository.beginUndoable(.createTag)
            try await repository.createTag(named: name, at: commit)
            finishes.append(await repository.finishUndoable(start))
        }
        return finishes
    }

    @Test func keepsABoundedHistoryAcrossLaunches() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let stack = UndoStack(storage: storage, limit: 2)
        for finish in try await tagRecords(["a", "b", "c"]) {
            stack.take(finish, for: .createTag)
        }
        #expect(stack.undoRecords.count == 2)
        #expect(stack.undoMenuTitle == "Undo New Tag")

        let undone = try #require(stack.nextUndo)
        stack.applied(undone, .undo)
        #expect(stack.nextRedo == undone)
        #expect(stack.redoMenuTitle == "Redo New Tag")

        let reopened = UndoStack(storage: storage, limit: 2)
        #expect(reopened.undoRecords == stack.undoRecords)
        #expect(reopened.redoRecords == stack.redoRecords)
    }

    @Test func somethingNewEndsTheRedoSide() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let stack = UndoStack(storage: nil)
        let finishes = try await tagRecords(["a", "b"])
        stack.take(finishes[0], for: .createTag)
        stack.applied(try #require(stack.nextUndo), .undo)
        stack.take(finishes[1], for: .createTag)
        #expect(stack.redoRecords.isEmpty)
        #expect(stack.undoRecords.count == 1)
    }

    @Test func anOperationThatCannotBeUndoneEndsTheHistory() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let stack = UndoStack(storage: nil)
        for finish in try await tagRecords(["a"]) {
            stack.take(finish, for: .createTag)
        }
        stack.take(.notUndoable("Too large"), for: .discard())
        #expect(stack.nextUndo == nil)
        #expect(stack.undoMenuTitle == "Can’t Undo Discard Changes")
    }

    @Test func forgettingARecordDropsWhatComesAfterIt() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let stack = UndoStack(storage: nil)
        for finish in try await tagRecords(["a", "b", "c"]) {
            stack.take(finish, for: .createTag)
        }
        let middle = stack.undoRecords[1]
        stack.forget(middle)
        #expect(stack.undoRecords.count == 1)
        #expect(stack.undoRecords.first?.id != middle.id)
    }
}
