import GitKit
import SwiftUI

/// The merge, rebase, cherry-pick or revert that has stopped, in detail.
/// Shows nothing while none is under way. The sidebar shows it below its
/// list; pressing it opens the working copy, where Continue, Skip and Abort are.
struct OperationBanner: View {
    var model: RepositoryModel

    @State private var operation: OngoingOperation?

    var body: some View {
        Group {
            if let operation {
                Button {
                    model.selection = .workingCopy
                } label: {
                    content(for: operation)
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: model.revision) {
            // Only ask while the snapshot says something is under way.
            guard model.snapshot?.state ?? .clean != .clean else {
                operation = nil
                return
            }
            operation = try? await model.repository.ongoingOperation()
        }
    }

    private func content(for operation: OngoingOperation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(of: operation))
                        .font(.headline)
                    Text(detail(of: operation))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: operation.hasConflicts ? "exclamationmark.triangle.fill" : "arrow.triangle.merge")
                    .foregroundStyle(operation.hasConflicts ? .orange : .accentColor)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
    }

    private func title(of operation: OngoingOperation) -> String {
        let subject = operation.summary.isEmpty ? "" : " “\(operation.summary)”"
        switch operation.kind {
        case .merge:
            return operation.summary.isEmpty ? "Merging" : operation.summary
        case .rebase:
            if let step = operation.step, let total = operation.total {
                return "Rebasing \(step) of \(total):\(subject)"
            }
            return "Rebasing"
        case .cherryPick:
            return "Cherry-picking\(subject)"
        case .revert:
            return "Reverting\(subject)"
        }
    }

    private func detail(of operation: OngoingOperation) -> String {
        var parts: [String] = []
        let count = operation.conflictedPaths.count
        if count > 0 {
            parts.append("\(count) \(count == 1 ? "file has" : "files have") conflicts. Resolve them, mark them resolved, then continue.")
        } else {
            parts.append("Conflicts are resolved. Continue to commit and carry on.")
        }
        if operation.queued > 0 {
            parts.append("\(operation.queued) more \(operation.queued == 1 ? "commit waits" : "commits wait") after this one.")
        }
        return parts.joined(separator: " ")
    }
}
