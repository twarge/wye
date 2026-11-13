import Foundation
import GitKit
import Observation

/// The rebasing sheets the menus ask for. The repository window shows them,
/// so they do not depend on the row that asked staying on screen.
@MainActor
@Observable
final class RebaseRequests {
    /// An interactive rebase, which the sheet plans.
    var interactive: InteractiveRebasePlan?
    /// Rebase onto: the new base to start with, if the menu named one.
    var onto: RebaseOntoRequest?
    /// An earlier commit whose message or author is being edited.
    var edit: CommitEditRequest?
}

/// Which commits an interactive rebase replays, and onto what.
enum InteractiveRebasePlan: Identifiable, Hashable {
    /// This commit and every one after it up to `HEAD`, replayed where
    /// they are: `git rebase -i <commit>^`.
    case from(OID)
    /// The commits `HEAD` has and this commit lacks, replayed onto it:
    /// `git rebase -i <commit>`.
    case onto(OID)

    var id: Self { self }
}

struct RebaseOntoRequest: Identifiable, Hashable {
    let id = UUID()
    /// The new base, as a full reference name or any revision; empty to choose.
    var newBase: String
}

struct CommitEditRequest: Identifiable, Hashable {
    enum Part: Hashable {
        case message
        case author
    }

    let commit: Commit
    let part: Part

    var id: String { "\(commit.id.hex)-\(part)" }
}

extension UndoOperation {
    static let interactiveRebase = UndoOperation(kind: .rebase, title: "Interactive Rebase", captures: [.index, .workTree])
    static let rebaseOnto = UndoOperation(kind: .rebase, title: "Rebase Onto", captures: [.index, .workTree])
    static let editMessage = UndoOperation(kind: .reword, title: "Edit Message")
    static let editAuthor = UndoOperation(kind: .reword, title: "Edit Author")
    static let fixupCommit = UndoOperation(kind: .commit, title: "Fixup Commit")
    static let squashCommit = UndoOperation(kind: .commit, title: "Squash Commit")
}

extension RepositoryModel {
    /// Runs an interactive rebase's plan, showing the working copy if it
    /// stops on a conflict.
    func runInteractiveRebase(onto: OID?, steps: [RebaseStep]) async {
        await perform(.interactiveRebase) { _ in
            let outcome = try await self.withAutostash("Rebase") { try $0.interactiveRebase(onto: onto, steps: steps) }
            self.showWorkingCopyIfStopped(outcome)
        }
    }

    /// Moves the commits the current branch has beyond `upstream` onto
    /// `newBase`.
    func rebaseCurrent(onto newBase: String, upstream: String) async {
        await perform(.rebaseOnto) { _ in
            let outcome = try await self.withAutostash("Rebase") { try $0.rebase(onto: newBase, upstream: upstream) }
            self.showWorkingCopyIfStopped(outcome)
        }
    }

    func editCommit(_ id: OID, message: String?, author: Signature?) async {
        await perform(author == nil ? .editMessage : .editAuthor) { repository in
            _ = try await repository.editCommit(id, message: message, author: author)
        }
    }

    /// Commits the staged changes as a `fixup!` or `squash!` of an earlier commit.
    func commitFixup(_ kind: FixupKind, for target: OID) async {
        await perform(kind == .fixup ? .fixupCommit : .squashCommit) { repository in
            _ = try await repository.commitFixup(kind, for: target)
        }
    }

    /// Continues or skips the operation under way through `body`, and when
    /// that finishes a rebase, records it for Undo: it was not recorded when
    /// it stopped part way.
    func recordingResumedRebase(_ body: () async -> Void) async {
        let start = await repository.resumedRebaseUndoStart()
        await body()
        guard let start, (snapshot?.state ?? .clean) == .clean else { return }
        undoStack.take(await repository.finishUndoable(start), for: .rebase)
    }

    private func showWorkingCopyIfStopped(_ outcome: OperationOutcome) {
        if case .stopped = outcome {
            selection = .workingCopy
        }
    }
}
