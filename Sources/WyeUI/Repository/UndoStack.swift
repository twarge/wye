import Foundation
import GitKit
import Observation

/// One repository's undo history: what Undo and Redo apply next, kept on
/// disk so it outlives the window. Records name objects by their IDs, and
/// the engine checks them before every use, so an old record that no
/// longer fits the repository is refused rather than applied.
@MainActor
@Observable
final class UndoStack {
    /// An undo or redo that would take pushed commits off a branch, waiting
    /// for the user to say go ahead.
    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let record: UndoRecord
        let direction: UndoDirection
        let message: String
    }

    /// An undo or redo that could not go ahead, and why.
    struct Refusal: Identifiable {
        let id = UUID()
        let record: UndoRecord
        let direction: UndoDirection
        let message: String
    }

    /// Oldest first; the last is undone next.
    private(set) var undoRecords: [UndoRecord] = []
    /// Oldest first; the last is redone next.
    private(set) var redoRecords: [UndoRecord] = []
    /// Set while an undo or redo runs, so another waits its turn.
    var isApplying = false
    var pendingConfirmation: PendingConfirmation?
    var refusal: Refusal?
    /// The last operation that could not be recorded, and why, until the
    /// next one is.
    private(set) var unrecorded: (title: String, reason: String)?

    /// How many records each side keeps.
    let limit: Int
    private let storage: URL?

    /// - Parameter storage: Where the history is kept; `nil` keeps it in memory.
    init(storage: URL?, limit: Int = 50) {
        self.storage = storage
        self.limit = limit
        load()
    }

    /// The history kept for a repository in the app's own folder.
    convenience init(repositoryID: UUID) {
        self.init(storage: .applicationSupportDirectory.appending(path: "Twig/Undo/\(repositoryID.uuidString).json"))
    }

    var nextUndo: UndoRecord? { undoRecords.last }
    var nextRedo: UndoRecord? { redoRecords.last }

    var undoMenuTitle: String {
        nextUndo.map { "Undo \($0.title)" } ?? unrecorded.map { "Can’t Undo \($0.title)" } ?? "Undo"
    }

    var redoMenuTitle: String {
        nextRedo.map { "Redo \($0.title)" } ?? "Redo"
    }

    /// Takes in how a recorded operation came out. Anything new makes the
    /// redo side meaningless. An operation that changed the repository but
    /// cannot be undone ends the history too: undoing what came before it
    /// would skip over it, which is not what Undo promises.
    func take(_ finish: UndoFinish, for operation: UndoOperation) {
        switch finish {
        case .recorded(let record):
            undoRecords.append(record)
            if undoRecords.count > limit {
                undoRecords.removeFirst(undoRecords.count - limit)
            }
            redoRecords = []
            unrecorded = nil
        case .unchanged:
            return
        case .notUndoable(let reason):
            undoRecords = []
            redoRecords = []
            unrecorded = (operation.title, reason)
        }
        save()
    }

    /// Moves a record across once it has been undone or redone.
    func applied(_ record: UndoRecord, _ direction: UndoDirection) {
        switch direction {
        case .undo:
            undoRecords.removeAll { $0.id == record.id }
            redoRecords.append(record)
        case .redo:
            redoRecords.removeAll { $0.id == record.id }
            undoRecords.append(record)
        }
        save()
    }

    /// Drops a record that cannot be applied, and everything it would have
    /// to be applied before: on the undo side the records older than it, on
    /// the redo side the newer ones.
    func forget(_ record: UndoRecord) {
        if let position = undoRecords.firstIndex(where: { $0.id == record.id }) {
            undoRecords.removeFirst(position + 1)
        }
        if let position = redoRecords.firstIndex(where: { $0.id == record.id }) {
            redoRecords.removeFirst(position + 1)
        }
        save()
    }

    func clear() {
        undoRecords = []
        redoRecords = []
        unrecorded = nil
        save()
    }

    // MARK: Storage

    private struct Stored: Codable {
        var version = 1
        var undo: [UndoRecord]
        var redo: [UndoRecord]
    }

    private func load() {
        guard let storage, let data = try? Data(contentsOf: storage),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1 else { return }
        undoRecords = Array(stored.undo.suffix(limit))
        redoRecords = Array(stored.redo.suffix(limit))
    }

    private func save() {
        guard let storage else { return }
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Stored(undo: undoRecords, redo: redoRecords))
            try data.write(to: storage, options: .atomic)
        } catch {
            // The history still works for this session; it just won't be
            // there next time.
        }
    }
}
