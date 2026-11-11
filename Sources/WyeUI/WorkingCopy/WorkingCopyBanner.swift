import GitKit
import SwiftUI

/// Names the operation under way, such as a merge stopped on conflicts, at
/// the top of the working copy, with Branching's Continue and Abort controls.
struct WorkingCopyBanner: View {
    var model: RepositoryModel
    var state: RepositoryState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                summary
                Spacer(minLength: 8)
                OperationControls(model: model, state: state)
            }
            VStack(alignment: .leading, spacing: 8) {
                summary
                OperationControls(model: model, state: state)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var summary: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(state.workingCopyTitle)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: conflictCount > 0 ? "exclamationmark.triangle.fill" : "arrow.triangle.merge")
                .foregroundStyle(.orange)
        }
    }

    private var conflictCount: Int {
        model.workingCopy.conflictedEntries.count
    }

    private var detail: String {
        switch conflictCount {
        case 0: "No conflicts are left."
        case 1: "1 file has conflicts to resolve."
        default: "\(conflictCount.formatted()) files have conflicts to resolve."
        }
    }
}

private extension RepositoryState {
    var workingCopyTitle: String {
        switch self {
        case .clean: "No operation under way"
        case .merging: "Merge in progress"
        case .reverting: "Revert in progress"
        case .cherryPicking: "Cherry-pick in progress"
        case .bisecting: "Bisect in progress"
        case .rebasing: "Rebase in progress"
        case .applyingMailbox: "Applying patches"
        }
    }
}
