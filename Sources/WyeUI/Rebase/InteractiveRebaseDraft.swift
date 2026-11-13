import Foundation
import GitKit
import Observation

/// The plan an interactive rebase sheet is editing: the commits in order,
/// what to do with each, and the messages typed for rewords and squashes.
@MainActor
@Observable
final class InteractiveRebaseDraft {
    struct Row: Identifiable, Hashable {
        let candidate: RebaseCandidate
        var action: RebaseStep.Action

        var id: OID { candidate.id }
    }

    let todo: RebaseTodo
    private(set) var rows: [Row]
    /// Whether `fixup!`, `squash!` and `amend!` commits are moved and marked
    /// as `--autosquash` does. Changing it starts the order and actions over.
    var autosquash: Bool {
        didSet { if autosquash != oldValue { reset() } }
    }
    /// Messages typed for rewords, by commit.
    private var rewordMessages: [OID: String] = [:]
    /// Messages typed for the commit a run of squashes makes, by the commit
    /// the run starts with.
    private var runMessages: [OID: String] = [:]

    init(todo: RebaseTodo) {
        self.todo = todo
        autosquash = todo.autosquashed != nil
        rows = []
        reset()
    }

    private func reset() {
        let steps = autosquash ? todo.autosquashed ?? todo.plainSteps : todo.plainSteps
        let candidates = Dictionary(todo.candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = steps.compactMap { step in candidates[step.commit].map { Row(candidate: $0, action: step.action) } }
    }

    // MARK: Editing

    func setAction(_ action: RebaseStep.Action, for id: OID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].action = action
    }

    func move(fromOffsets offsets: IndexSet, toOffset offset: Int) {
        let moving = offsets.sorted().map { rows[$0] }
        var remaining = rows.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = offset - offsets.filter { $0 < offset }.count
        remaining.insert(contentsOf: moving, at: min(max(insertion, 0), remaining.count))
        rows = remaining
    }

    func canMove(_ id: OID, by delta: Int) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        return rows.indices.contains(index + delta)
    }

    /// Moves a row one place earlier (`-1`) or later (`1`).
    func move(_ id: OID, by delta: Int) {
        guard canMove(id, by: delta), let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows.swapAt(index, index + delta)
    }

    // MARK: Messages

    /// Whether the row's action asks for a message: a reword, or a squash
    /// into the commit before.
    func asksForMessage(_ row: Row) -> Bool {
        row.action == .reword || (row.action == .squash && runHead(of: row.id) != nil)
    }

    /// The message the row's commit will get: for a reword, what was typed or
    /// its own; for a squash, what was typed for its run or git's combination.
    func message(for id: OID) -> String {
        guard let row = rows.first(where: { $0.id == id }) else { return "" }
        if row.action.meldsIntoPrevious, let head = runHead(of: id) {
            return runMessages[head] ?? proposedRunMessage(startingAt: head)
        }
        return rewordMessages[id] ?? trimmed(row.candidate.message)
    }

    func setMessage(_ message: String, for id: OID) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        if row.action.meldsIntoPrevious, let head = runHead(of: id) {
            runMessages[head] = message
        } else {
            rewordMessages[id] = message
        }
    }

    /// The pick or reword a squash or fixup joins: the nearest row before it
    /// that is neither, passing over drops.
    private func runHead(of id: OID) -> OID? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return rows[..<index].last { !$0.action.meldsIntoPrevious && $0.action != .drop }?.id
    }

    /// git's message for the commit a run makes, from the run's first commit
    /// (as reworded) and the squashes and fixups after it.
    private func proposedRunMessage(startingAt head: OID) -> String {
        guard let start = rows.firstIndex(where: { $0.id == head }) else { return "" }
        let first = rows[start]
        let firstMessage = first.action == .reword ? committed(rewordMessages[head] ?? first.candidate.message)
            : first.candidate.message
        var followers: [(action: RebaseStep.Action, message: String)] = []
        for row in rows[(start + 1)...] where row.action != .drop {
            guard row.action.meldsIntoPrevious else { break }
            followers.append((row.action, row.candidate.message))
        }
        return trimmed(SquashMessage.combined(first: firstMessage, followers: followers))
    }

    // MARK: The plan

    /// The steps to run. A run's typed message rides on its last squash or
    /// fixup, as the engine takes it.
    var steps: [RebaseStep] {
        var steps = rows.map { RebaseStep(commit: $0.id, action: $0.action) }
        for index in steps.indices {
            switch steps[index].action {
            case .reword:
                steps[index].message = rewordMessages[steps[index].commit]
            case .squash, .fixup, .fixupWithMessage:
                guard isLastOfRun(index), let head = runHead(of: steps[index].commit),
                      runContainsSquash(endingAt: index), let message = runMessages[head] else { continue }
                steps[index].message = message
            case .pick, .drop:
                break
            }
        }
        return steps
    }

    /// What stops the plan running, said for the sheet; `nil` when it can.
    var problem: String? {
        if let first = rows.first(where: { $0.action != .drop }), first.action.meldsIntoPrevious {
            return "“\(first.candidate.commit.summary)” cannot be squashed or fixed up: no commit comes before it."
        }
        if todo.onto == nil && rows.allSatisfy({ $0.action == .drop }) {
            return "The branch would have no commits left. Keep at least one."
        }
        if rows.contains(where: { asksForMessage($0) && message(for: $0.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "A commit message cannot be empty."
        }
        return nil
    }

    /// Whether running the plan would change nothing: every commit picked,
    /// in its order.
    var isUnchanged: Bool {
        !todo.changesBase && rows.map(\.id) == todo.candidates.map(\.id) && rows.allSatisfy { $0.action == .pick }
    }

    var droppedCount: Int {
        rows.filter { $0.action == .drop }.count
    }

    private func isLastOfRun(_ index: Int) -> Bool {
        let later = rows[(index + 1)...].first { $0.action != .drop }
        return later.map { !$0.action.meldsIntoPrevious } ?? true
    }

    private func runContainsSquash(endingAt index: Int) -> Bool {
        var position = index
        while position >= 0, rows[position].action.meldsIntoPrevious || rows[position].action == .drop {
            if rows[position].action == .squash { return true }
            position -= 1
        }
        return false
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func committed(_ text: String) -> String {
        trimmed(text) + "\n"
    }
}

extension RebaseStep.Action {
    /// The name the sheet's menu gives it.
    var title: String {
        switch self {
        case .pick: "Pick"
        case .reword: "Reword"
        case .squash: "Squash"
        case .fixup: "Fixup"
        case .fixupWithMessage: "Fixup, Use Message"
        case .drop: "Drop"
        }
    }

    var explanation: String {
        switch self {
        case .pick: "Keep the commit as it is"
        case .reword: "Keep the commit with a new message"
        case .squash: "Meld into the commit above, combining the messages"
        case .fixup: "Meld into the commit above, keeping that one’s message"
        case .fixupWithMessage: "Meld into the commit above, using this commit’s message"
        case .drop: "Leave the commit out"
        }
    }

    var systemImage: String {
        switch self {
        case .pick: "checkmark.circle"
        case .reword: "pencil.circle"
        case .squash: "arrow.up.and.line.horizontal.and.arrow.down"
        case .fixup: "arrow.up.to.line"
        case .fixupWithMessage: "arrow.up.to.line.compact"
        case .drop: "trash"
        }
    }
}
