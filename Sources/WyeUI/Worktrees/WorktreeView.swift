import GitKit
import SwiftUI

/// A worktree's detail: where it is, what it has checked out, whether it is
/// locked, and what can be done with it.
struct WorktreeView: View {
    var model: RepositoryModel
    var name: String

    var body: some View {
        if let worktree = model.worktree(named: name) {
            Form {
                Section {
                    LabeledContent("Path") {
                        Text(worktree.path)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Checked Out", value: worktree.headSummary)
                    if let target = worktree.head?.target {
                        LabeledContent("Commit") {
                            Text(target.abbreviated())
                                .font(.code)
                                .textSelection(.enabled)
                        }
                    }
                    LabeledContent("Kind", value: worktree.isMain ? "Main worktree" : "Linked worktree “\(worktree.name)”")
                    if worktree.isCurrent {
                        LabeledContent("Window", value: "This window shows it")
                    }
                } footer: {
                    if let note = footnote(worktree) {
                        Text(note)
                    }
                }

                if !worktree.isMain {
                    Section {
                        LabeledContent("Locked", value: worktree.isLocked ? (worktree.lockReason ?? "Yes") : "No")
                    }
                }

                Section {
                    HStack {
                        Button("Open", systemImage: "arrow.up.forward.app") {
                            model.nested.opening = .worktree(name)
                        }
                        .disabled(worktree.isCurrent || worktree.isMissing)
                        Menu("More", systemImage: "ellipsis.circle") {
                            WorktreeActions(model: model, worktree: worktree)
                        }
                        .fixedSize()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(worktree.displayName)
        } else {
            ContentUnavailableView("No Worktree", systemImage: "square.on.square")
        }
    }

    private func footnote(_ worktree: Worktree) -> String? {
        if worktree.isMissing {
            return worktree.isLocked
                ? "Its folder is not there. It is locked, so it is kept until it comes back."
                : "Its folder is gone. Prune Worktrees removes what the repository keeps for it."
        }
        if !worktree.isReachable {
            return "Wye has not been given this folder. Open asks you to choose it, which gives Wye access."
        }
        return nil
    }
}
