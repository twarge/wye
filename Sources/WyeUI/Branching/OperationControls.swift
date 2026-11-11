import GitKit
import SwiftUI

/// Continue, Skip and Abort for the merge, rebase, cherry-pick or revert
/// under way. Used by the working copy's banner and the sidebar's.
struct OperationControls: View {
    var model: RepositoryModel
    var state: RepositoryState

    @State private var isConfirmingAbort = false

    var body: some View {
        if let noun {
            HStack {
                Button("Continue") { Task { await model.continueOperation() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(hasConflicts)
                    .help(hasConflicts ? "Resolve the conflicts first" : "Commit this step and carry on")
                // A merge is a single step: it can only be finished or given up.
                if state != .merging {
                    Button("Skip") { Task { await model.skipOperation() } }
                        .help("Leave out this commit and carry on with the rest")
                }
                Button("Abort", role: .destructive) { isConfirmingAbort = true }
                    .help("Give up the \(noun) and return to where it started")
            }
            .controlSize(.small)
            .confirmationDialog("Abort the \(noun)?", isPresented: $isConfirmingAbort, titleVisibility: .visible) {
                Button("Abort \(noun.capitalized)", role: .destructive) {
                    Task { await model.abortOperation() }
                }
            } message: {
                Text(abortWarning)
            }
        }
    }

    private var hasConflicts: Bool {
        model.workingCopy.entries.contains { $0.isConflicted }
    }

    /// The operation, as a sentence names it; `nil` for one Wye cannot
    /// continue or abort.
    private var noun: String? {
        switch state {
        case .merging: "merge"
        case .rebasing: "rebase"
        case .cherryPicking: "cherry-pick"
        case .reverting: "revert"
        case .clean, .bisecting, .applyingMailbox: nil
        }
    }

    private var abortWarning: String {
        switch state {
        case .rebasing:
            "The branch goes back to where it was before the rebase. Conflict resolutions and the commits already replayed are discarded."
        case .cherryPicking, .reverting:
            "The files it changed go back to how they were and conflict resolutions are lost. Commits it already made in this run are undone. Other local changes are kept."
        default:
            "The files the merge changed go back to how they were and conflict resolutions are lost. Other local changes are kept."
        }
    }
}
