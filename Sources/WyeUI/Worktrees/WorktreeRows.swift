import GitKit
import SwiftUI

@MainActor
extension Worktree {
    /// What its `HEAD` is, in a few words: the branch, or the detached commit.
    var headSummary: String {
        switch head {
        case .branch(let name, _), .unborn(let name): RepositoryModel.displayName(ofReference: name)
        case .detached(let id): "Detached at \(id.abbreviated())"
        case nil: "Unknown"
        }
    }

    /// A word on its state, for the main, missing and unreachable ones.
    var stateNote: String? {
        if isMissing { return "Missing" }
        if !isReachable { return "No Access" }
        if isMain { return "Main" }
        return nil
    }
}

/// A worktree in the sidebar: its folder, its branch, and whether it is
/// locked, current or gone.
struct WorktreeLabel: View {
    var worktree: Worktree

    var body: some View {
        Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(worktree.displayName)
                        .lineLimit(1)
                    Text(worktree.headSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if worktree.isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Locked")
                }
                if worktree.isMissing {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Missing")
                }
                if worktree.isCurrent {
                    Text("This")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(.quaternary, in: .capsule)
                }
            }
        } icon: {
            Image(systemName: worktree.isMain ? "folder" : "square.on.square")
        }
        .help(worktree.path)
    }
}

/// The actions on one worktree, for its context menu and its detail.
struct WorktreeActions: View {
    var model: RepositoryModel
    var worktree: Worktree

    var body: some View {
        let name = worktree.name
        Button("Open", systemImage: "arrow.up.forward.app") {
            model.nested.opening = .worktree(name)
        }
        .disabled(worktree.isCurrent || worktree.isMissing)
        if Platform.canRevealFiles {
            Button(Platform.revealInFileBrowserTitle, systemImage: "folder") {
                Platform.revealInFileBrowser(URL(filePath: worktree.path, directoryHint: .isDirectory))
            }
            .disabled(worktree.isMissing || !worktree.isReachable)
        }
        Button("Copy Path", systemImage: "doc.on.doc") {
            Platform.copyToClipboard(worktree.path)
        }
        if !worktree.isMain {
            Divider()
            if worktree.isLocked {
                Button("Unlock", systemImage: "lock.open") {
                    Task { await model.unlockWorktree(name) }
                }
            } else {
                Button("Lock…", systemImage: "lock") {
                    model.nested.sheet = .lockWorktree(name)
                }
            }
            Button("Move…", systemImage: "folder.badge.gearshape") {
                model.nested.sheet = .moveWorktree(name)
            }
            .disabled(worktree.isLocked || worktree.isCurrent || worktree.isMissing)
            Divider()
            Button("Remove…", systemImage: "trash", role: .destructive) {
                model.nested.sheet = .removeWorktree(name)
            }
            .disabled(worktree.isLocked || worktree.isCurrent)
        }
    }
}

/// The actions on the worktrees as a whole.
struct AllWorktreesActions: View {
    var model: RepositoryModel?

    var body: some View {
        Button("Add Worktree…", systemImage: "plus") {
            model?.nested.sheet = .addWorktree(nil)
        }
        .disabled(model?.snapshot?.head.target == nil)
        Button("Prune Worktrees", systemImage: "scissors") {
            Task { await model?.pruneWorktrees() }
        }
        .disabled(model?.snapshot?.worktrees.contains(where: \.isPrunable) != true)
    }
}
