import GitKit
import SwiftUI

/// Chooses how to merge a branch into the current one.
struct MergeSheet: View {
    var model: RepositoryModel
    /// The branch, remote branch or tag to merge, by full reference name.
    var reference: String

    @State private var mode = MergeMode.fastForwardWhenPossible
    @State private var message = ""

    var body: some View {
        BranchingSheetForm(title: "Merge", confirmTitle: "Merge", confirm: merge) {
            Section {
                LabeledContent("Merge", value: RepositoryModel.displayName(ofReference: reference))
                LabeledContent("Into", value: model.headBranchName ?? "Detached HEAD")
            }
            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(MergeMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(mode.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Message", text: $message, prompt: Text(defaultMessage), axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                Text("Used when the merge makes a commit. Leave it empty for the usual message.")
            }
        }
    }

    private var defaultMessage: String {
        let name = RepositoryModel.displayName(ofReference: reference)
        return mode == .squash ? "Squashed commit of “\(name)”" : "Merge “\(name)”"
    }

    private func merge() {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = mode
        let reference = reference
        Task {
            await model.mergeIntoCurrent(reference, mode: mode, message: message.isEmpty ? nil : message)
        }
    }
}

extension MergeMode {
    var title: String {
        switch self {
        case .fastForwardWhenPossible: "Fast-Forward When Possible"
        case .alwaysCommit: "Always Make a Merge Commit"
        case .squash: "Squash into One Commit"
        }
    }

    var explanation: String {
        switch self {
        case .fastForwardWhenPossible:
            "If the current branch has no commits of its own, it moves forward to the other one. Otherwise a merge commit joins them."
        case .alwaysCommit:
            "A merge commit joins the two branches even when the current one could simply move forward, so the history shows where the work came in."
        case .squash:
            "All the other branch’s changes become one ordinary commit on the current branch. The other branch is not recorded as merged."
        }
    }
}

/// Confirms replaying the current branch onto another.
struct RebaseSheet: View {
    var model: RepositoryModel
    var onto: String

    @State private var replayed: Int?

    var body: some View {
        BranchingSheetForm(
            title: "Rebase", confirmTitle: "Rebase", canConfirm: model.headBranchName != nil, confirm: rebase
        ) {
            Section {
                LabeledContent("Rebase", value: model.headBranchName ?? "Detached HEAD")
                LabeledContent("Onto", value: RepositoryModel.displayName(ofReference: onto))
            } footer: {
                Text(explanation)
            }
        }
        .task {
            // A revision picked by its hash is no reference.
            guard let target = model.snapshot?.branchingTarget(of: onto) ?? OID(hex: onto) else { return }
            replayed = try? await model.repository.headCommitCount(notIn: target)
        }
    }

    private var explanation: String {
        let commits = replayed.map { "its \($0) \($0 == 1 ? "commit" : "commits")" } ?? "its commits"
        return "Replays \(commits) on top of “\(RepositoryModel.displayName(ofReference: onto))”, "
            + "making new commits in place of the old ones. If the branch was already pushed, "
            + "publishing it again needs a force push."
    }

    private func rebase() {
        let onto = onto
        Task { await model.rebaseCurrent(onto: onto) }
    }
}

extension RepositorySnapshot {
    /// The commit a branch, remote branch or tag, by full name, points at.
    func branchingTarget(of reference: String) -> OID? {
        branches.first { $0.id == reference }?.target
            ?? remotes.flatMap(\.branches).first { $0.id == reference }?.target
            ?? tags.first { $0.id == reference }?.target
    }
}
