import GitKit
import SwiftUI

/// What a merge or rebase would do, worked out in the background as the
/// sheet opens: a fast-forward, a clean merge, or conflicts, with the files.
struct MergePreviewSection: View {
    enum Operation: Hashable {
        /// Merging a revision into `HEAD`, in a mode, or only fast-forwarding.
        case merge(String, mode: MergeMode?)
        case rebase(onto: String)
    }

    var model: RepositoryModel
    var operation: Operation
    /// A note under the verdict, such as how fresh the remote branch is.
    var note: String?

    var body: some View {
        Section {
            MergePreviewLine(model: model, operation: operation)
        } footer: {
            Text(note ?? "Checked without changing anything. Local changes are not part of it.")
        }
    }
}

/// The verdict as one line, with the conflicting files to expand.
struct MergePreviewLine: View {
    var model: RepositoryModel
    var operation: MergePreviewSection.Operation

    private enum Progress: Equatable {
        case checking
        case done(MergePreview)
        case failed(String)
    }

    @State private var progress = Progress.checking
    @State private var showsFiles = false

    var body: some View {
        content
            // A new choice cancels the check under way and starts another;
            // the mode only changes the wording.
            .task(id: target) { await check() }
    }

    @ViewBuilder
    private var content: some View {
        switch progress {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for conflicts…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label("Could not check: \(message)", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .done(let preview):
            if case .conflicts(let paths) = preview.verdict {
                DisclosureGroup(isExpanded: $showsFiles) {
                    ForEach(paths, id: \.self) { path in
                        Text(path)
                            .font(.code)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } label: {
                    Label(MergePreviewText.headline(preview, operation: operation), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else {
                Label(MergePreviewText.headline(preview, operation: operation), systemImage: symbol(preview.verdict))
                    .foregroundStyle(preview.verdict == .upToDate ? Color.secondary : Color.green)
            }
        }
    }

    private var target: String {
        switch operation {
        case .merge(let revision, _): "merge \(revision)"
        case .rebase(let onto): "rebase \(onto)"
        }
    }

    private func symbol(_ verdict: MergePreview.Verdict) -> String {
        switch verdict {
        case .upToDate: "checkmark.circle"
        case .fastForward: "arrow.up.forward.circle.fill"
        case .clean, .conflicts: "checkmark.circle.fill"
        }
    }

    private func check() async {
        progress = .checking
        showsFiles = false
        let repository = model.repository
        do {
            let preview: MergePreview
            switch operation {
            case .merge(let revision, _): preview = try await repository.previewMerge(of: revision)
            case .rebase(let onto): preview = try await repository.previewRebase(onto: onto)
            }
            try Task.checkCancellation()
            progress = .done(preview)
        } catch is CancellationError {
            // Replaced by the check for the new choice.
        } catch {
            progress = .failed(error.localizedDescription)
        }
    }
}

/// The words for a preview, apart from the view so they can be tested.
enum MergePreviewText {
    static func headline(_ preview: MergePreview, operation: MergePreviewSection.Operation) -> String {
        switch (preview.verdict, operation) {
        case (.upToDate, _):
            return "Already up to date"
        case (.fastForward, .merge(_, let mode)):
            switch mode {
            case .fastForwardWhenPossible?, nil: return "Fast-forward"
            case .alwaysCommit?: return "Merges cleanly (a fast-forward would also do)"
            case .squash?: return "Merges cleanly"
            }
        case (.fastForward, .rebase):
            return "Fast-forward: there are no commits of its own to replay"
        case (.clean, .merge(_, let mode)):
            return mode == nil ? "Cannot fast-forward, but would merge cleanly" : "Merges cleanly"
        case (.clean, .rebase):
            return "Replays \(commits(preview.commitCount)) cleanly"
        case (.conflicts(let paths), .merge(_, let mode)):
            let files = "\(paths.count) \(paths.count == 1 ? "file" : "files")"
            return mode == nil ? "Cannot fast-forward; a merge would conflict in \(files)" : "Conflicts in \(files)"
        case (.conflicts(let paths), .rebase):
            let files = "\(paths.count) \(paths.count == 1 ? "file" : "files")"
            guard let step = preview.stoppingStep else { return "Conflicts in \(files)" }
            let commit = preview.stoppingCommit.map { " (\($0.abbreviated()))" } ?? ""
            return "Conflicts in \(files) at commit \(step) of \(preview.commitCount)\(commit)"
        }
    }

    private static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }
}

extension MergePreviewText {
    static let pullNote = "As of the last fetch. The pull fetches first, which may bring more."
}

extension PullMode {
    /// The preview of pulling a remote branch this way.
    func previewOperation(of remoteBranch: String) -> MergePreviewSection.Operation {
        switch self {
        case .merge: .merge(remoteBranch, mode: .fastForwardWhenPossible)
        case .rebase: .rebase(onto: remoteBranch)
        case .fastForwardOnly: .merge(remoteBranch, mode: nil)
        }
    }
}
