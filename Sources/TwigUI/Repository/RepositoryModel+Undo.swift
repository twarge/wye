import Foundation
import GitKit

extension RepositoryModel {
    /// Runs an operation as `perform(_:)` does, recording it so Undo can
    /// reverse it. The repository is read before and after, so a call site
    /// only says what it is doing:
    ///
    /// ```swift
    /// await perform(.createTag) { try await $0.createTag(named: name, at: commit) }
    /// ```
    func perform(_ undoable: UndoOperation, _ operation: (Repository) async throws -> Void) async {
        let recordedSubmodules = recordedSubmoduleCommits()
        // Named in the activity log by what it does.
        await ActivityContext.$operationTitle.withValue(undoable.title) {
            await perform { repository in
                let start = await repository.beginUndoable(undoable)
                try await operation(repository)
                let finish = await repository.finishUndoable(start)
                self.undoStack.take(finish, for: undoable)
            }
        }
        await followRecordedSubmodules(from: recordedSubmodules)
    }

    var canUndo: Bool { undoStack.nextUndo != nil && !undoStack.isApplying }
    var canRedo: Bool { undoStack.nextRedo != nil && !undoStack.isApplying }

    func undo() async {
        guard let record = undoStack.nextUndo else { return }
        await apply(record, .undo, confirmed: false)
    }

    func redo() async {
        guard let record = undoStack.nextRedo else { return }
        await apply(record, .redo, confirmed: false)
    }

    /// Goes ahead with an undo or redo the user has confirmed.
    func confirm(_ pending: UndoStack.PendingConfirmation) async {
        undoStack.pendingConfirmation = nil
        await apply(pending.record, pending.direction, confirmed: true)
    }

    /// Checks a record against the repository, asks first when it would
    /// take pushed commits off a branch, and applies it. A record that does
    /// not fit any more is refused with the reason, and stays in the history
    /// until the user forgets it.
    private func apply(_ record: UndoRecord, _ direction: UndoDirection, confirmed: Bool) async {
        guard !undoStack.isApplying else { return }
        undoStack.isApplying = true
        defer { undoStack.isApplying = false }
        diskChanges.operationBegan()
        do {
            if !confirmed, case .needsConfirmation(let message) = try await repository.undoPreflight(record, direction) {
                undoStack.pendingConfirmation = .init(record: record, direction: direction, message: message)
                diskChanges.operationEnded()
                return
            }
            try await repository.applyUndo(record, direction)
            undoStack.applied(record, direction)
            if direction == .undo, record.operation.kind == .commit {
                await restoreMessage(of: record)
            }
        } catch {
            undoStack.refusal = .init(record: record, direction: direction, message: error.localizedDescription)
        }
        diskChanges.operationEnded()
        await refresh()
        dropSelectionOfGoneReferences()
    }

    /// Undoing a commit puts its message back in an empty composer, so
    /// committing again is one step.
    private func restoreMessage(of record: UndoRecord) async {
        guard workingCopy.subject.isEmpty, workingCopy.details.isEmpty, !workingCopy.isAmending,
              case .symbolic(let branch) = record.head.after,
              let id = record.refs[branch]?.after ?? nil,
              let commit = try? await repository.commit(id) else { return }
        workingCopy.subject = commit.summary
        workingCopy.details = commit.body
    }

    /// An undo can take away the branch or tag the sidebar shows.
    private func dropSelectionOfGoneReferences() {
        guard let snapshot else { return }
        switch selection {
        case .branch(let id) where !snapshot.branches.contains { $0.id == id }:
            selection = .history
        case .tag(let id) where !snapshot.tags.contains { $0.id == id }:
            selection = .history
        default:
            break
        }
    }
}
