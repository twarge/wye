import GitKit
import SwiftUI

/// Asks for a branch's new name.
struct RenameBranchSheet: View {
    var model: RepositoryModel
    /// The branch, by full reference name.
    var branch: String

    @State private var name: String

    init(model: RepositoryModel, branch: String) {
        self.model = model
        self.branch = branch
        _name = State(initialValue: RepositoryModel.displayName(ofReference: branch))
    }

    var body: some View {
        BranchingSheetForm(title: "Rename Branch", confirmTitle: "Rename", canConfirm: canRename, confirm: rename) {
            TextField("Name", text: $name)
                .autocorrectionDisabled()
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var canRename: Bool {
        !trimmed.isEmpty && trimmed != RepositoryModel.displayName(ofReference: branch)
    }

    private func rename() {
        let name = trimmed
        let branch = branch
        Task { await model.renameBranch(branch, to: name) }
    }
}

/// Confirms deleting a branch, saying how many commits only it has, and
/// offers to delete the remote branch it tracks along with it. A branch a
/// linked worktree has checked out can go only with that worktree, which
/// it offers to remove first.
struct DeleteBranchSheet: View {
    var model: RepositoryModel
    var branch: String

    @Environment(RepositoryLibrary.self) private var library
    /// Commits that nothing kept would still contain: `HEAD`, and the
    /// branch's upstream unless that is being deleted too.
    @State private var unmerged: Int?
    @State private var deletesRemoteBranch = false
    /// Whether the worktree that has the branch checked out is removed first.
    @State private var removesWorktree = false
    /// How many files differ in that worktree; `nil` until counted, or when
    /// it cannot be.
    @State private var worktreeChanges: Int?
    @State private var isCountingChanges = true

    var body: some View {
        BranchingSheetForm(
            title: "Delete Branch",
            confirmTitle: losesSomething ? "Delete Anyway" : "Delete",
            isDestructive: true,
            canConfirm: canDelete,
            confirm: delete
        ) {
            Section {
                LabeledContent("Branch", value: name)
            } footer: {
                Text(explanation)
            }
            if let tracked {
                Section {
                    Toggle("Also Delete “\(tracked.name)”", isOn: $deletesRemoteBranch)
                    if deletesRemoteBranch {
                        Label {
                            Text("Deletes “\(remoteParts.branch)” on “\(remoteParts.remote)” for everyone who uses it. "
                                 + "This can’t be undone from Wye.")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            if let holder {
                Section {
                    Toggle("Also Remove Worktree “\(holder.displayName)”", isOn: $removesWorktree)
                        .disabled(holderObstacle != nil)
                    if removesWorktree {
                        Label {
                            Text(worktreeWarning(holder))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    if !removesWorktree {
                        Text(worktreeExplanation(holder))
                    }
                }
            }
        }
        .task(id: deletesRemoteBranch) {
            unmerged = nil
            unmerged = (try? await model.repository.unmergedCommitCount(
                of: branch, countingUpstream: !deletesRemoteBranch
            )) ?? 0
        }
        .task {
            defer { isCountingChanges = false }
            guard let holder, holderObstacle == nil else { return }
            worktreeChanges = await model.changeCount(in: holder, library: library)
        }
    }

    private var name: String { RepositoryModel.displayName(ofReference: branch) }

    /// The linked worktree that has the branch checked out, which git
    /// requires gone before the branch can be deleted.
    private var holder: Worktree? { model.worktree(holding: branch) }

    /// Why that worktree cannot be removed from here.
    private var holderObstacle: String? {
        holder.flatMap { model.removalObstacle(for: $0, library: library) }
    }

    private var canDelete: Bool {
        guard unmerged != nil, !(deletesRemoteBranch && model.isTransferring) else { return false }
        return holder == nil || (removesWorktree && !isCountingChanges)
    }

    /// Whether confirming loses commits, or changes in the worktree.
    private var losesSomething: Bool {
        unmerged ?? 0 > 0 || (removesWorktree && worktreeChanges ?? 0 > 0)
    }

    /// Why the branch cannot go as things are.
    private func worktreeExplanation(_ holder: Worktree) -> String {
        let held = "“\(name)” is checked out in the worktree “\(holder.displayName)”, "
            + "and a branch can be deleted only when no worktree has it checked out."
        guard let holderObstacle else { return "\(held) Remove the worktree to delete the branch." }
        return "\(held) \(holderObstacle)"
    }

    /// What removing the worktree loses.
    private func worktreeWarning(_ holder: Worktree) -> String {
        let undo = "Undo brings the branch back, but not the worktree."
        if holder.isMissing {
            return "The worktree’s folder is already gone, so only the repository’s record of it is removed. \(undo)"
        }
        let folder = "Deletes the worktree’s folder first."
        switch worktreeChanges {
        case let count? where count > 0:
            return "\(folder) It has \(count) uncommitted \(count == 1 ? "change" : "changes") or untracked "
                + "\(count == 1 ? "file" : "files"), which \(count == 1 ? "is" : "are") lost and cannot be recovered. \(undo)"
        case 0:
            return "\(folder) It has no uncommitted changes. \(undo)"
        default:
            return "\(folder) Any uncommitted changes or untracked files in it are lost and cannot be recovered. \(undo)"
        }
    }

    /// The remote branch this one tracks, when there is one to delete.
    private var tracked: Branch? {
        guard let upstream = model.snapshot?.branches.first(where: { $0.id == branch })?.upstream else { return nil }
        return model.snapshot?.remotes.lazy.flatMap(\.branches).first { $0.name == upstream.name }
    }

    private var remoteParts: (remote: String, branch: String) {
        tracked.map { model.remoteParts(of: $0.id) } ?? ("", "")
    }

    private var explanation: String {
        let kept = deletesRemoteBranch ? "the current branch" : "the current branch or its upstream"
        switch unmerged {
        case nil:
            return "Checking what the branch holds…"
        case 0:
            return "Everything on “\(name)” is merged into \(kept), so no commits are lost."
        case let count?:
            return "“\(name)” has \(count) \(count == 1 ? "commit" : "commits") that \(count == 1 ? "is" : "are") not merged "
                + "into \(kept). Deleting it loses \(count == 1 ? "that commit" : "them") "
                + "unless another branch or tag holds \(count == 1 ? "it" : "them")."
        }
    }

    private func delete() {
        let branch = branch
        let force = unmerged ?? 0 > 0
        let remoteBranch = deletesRemoteBranch ? tracked?.id : nil
        let worktree = removesWorktree ? holder?.name : nil
        let library = library
        Task {
            if let worktree {
                await model.deleteBranch(
                    branch, force: force, alsoDeleting: remoteBranch, removingWorktree: worktree, library: library
                )
            } else if let remoteBranch {
                await model.deleteBranch(branch, force: force, alsoDeleting: remoteBranch)
            } else {
                await model.deleteBranch(branch, force: force)
            }
        }
    }
}

/// Confirms deleting a tag.
struct DeleteTagSheet: View {
    var model: RepositoryModel
    var tag: String

    var body: some View {
        BranchingSheetForm(title: "Delete Tag", confirmTitle: "Delete", isDestructive: true, confirm: delete) {
            Section {
                LabeledContent("Tag", value: RepositoryModel.displayName(ofReference: tag))
            } footer: {
                Text("The tag is removed from this repository, along with its message if it has one. "
                    + "Commits stay where they are. A remote that has the tag keeps it.")
            }
        }
    }

    private func delete() {
        let tag = tag
        Task { await model.deleteTag(tag) }
    }
}

/// Asks for a new tag's name and, for an annotated tag, its message, and
/// whether to push it to the remotes once made.
struct NewTagSheet: View {
    var model: RepositoryModel
    var commit: OID

    @State private var name = ""
    @State private var isAnnotated = false
    @State private var message = ""
    /// The last choice made here, kept when the tag is created.
    @State private var pushes = PushPreferences.pushesNewTags()

    var body: some View {
        BranchingSheetForm(title: "New Tag", confirmTitle: "Create", canConfirm: canCreate, confirm: create) {
            Section {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                LabeledContent("Commit") {
                    Text(commit.abbreviated())
                        .font(.code)
                }
            } footer: {
                if exists {
                    Text("A tag named “\(trimmedName)” already exists.")
                }
            }
            Section {
                Toggle("Annotated", isOn: $isAnnotated)
                if isAnnotated {
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...8)
                }
            } footer: {
                Text(isAnnotated
                    ? "An annotated tag records who made it, when, and a message."
                    : "A lightweight tag is only a name for the commit.")
            }
            let remotes = model.remoteNames
            if let pushTitle = RepositoryModel.newTagPushTitle(remotes: remotes) {
                Section {
                    Toggle(pushTitle, isOn: $pushes)
                } footer: {
                    if remotes.count == 1 {
                        Text("Once made, the tag is pushed to \(remotes[0]). Undo deletes it here but not on \(remotes[0]).")
                    } else {
                        Text("Once made, the tag is pushed to each remote in turn. Undo deletes it here but not on the remotes.")
                    }
                }
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var exists: Bool {
        model.snapshot?.tags.contains { $0.name == trimmedName } == true
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty && !exists
            && (!isAnnotated || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func create() {
        let name = trimmedName
        let message = isAnnotated ? message : nil
        let commit = commit
        let pushing = pushes && model.hasRemotes
        if model.hasRemotes {
            PushPreferences.setPushesNewTags(pushes)
        }
        Task { await model.createTag(named: name, at: commit, message: message, pushing: pushing) }
    }
}

/// Chooses how far to reset the current branch, and for a hard reset says
/// what will be lost.
struct ResetSheet: View {
    var model: RepositoryModel
    var commit: OID

    @State private var mode = ResetMode.mixed
    /// Commits the branch has past `commit`, which leave it.
    @State private var leaving: Int?

    var body: some View {
        BranchingSheetForm(
            title: "Reset Branch",
            confirmTitle: mode == .hard ? "Discard and Reset" : "Reset",
            isDestructive: mode == .hard,
            confirm: reset
        ) {
            Section {
                LabeledContent("Branch", value: model.headBranchName ?? "Detached HEAD")
                LabeledContent("To") {
                    Text(commit.abbreviated())
                        .font(.code)
                }
            } footer: {
                if let leaving, leaving > 0 {
                    Text("\(leaving) \(leaving == 1 ? "commit leaves" : "commits leave") the branch. "
                        + "\(leaving == 1 ? "It stays" : "They stay") in the reflog for a while.")
                }
            }
            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(ResetMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(mode.explanation)
            }
            if mode == .hard, !discarded.isEmpty {
                Section("Uncommitted Changes That Will Be Lost") {
                    ForEach(discarded.prefix(12)) { entry in
                        Text(entry.path)
                            .font(.code)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if discarded.count > 12 {
                        Text("and \(discarded.count - 12) more")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            leaving = try? await model.repository.headCommitCount(notIn: commit)
        }
    }

    /// Tracked files with changes, which a hard reset overwrites. Untracked
    /// files are left alone.
    private var discarded: [StatusEntry] {
        model.workingCopy.entries.filter { $0.staged != nil || ($0.unstaged != nil && $0.unstaged != .untracked) }
    }

    private func reset() {
        let mode = mode
        let commit = commit
        Task { await model.resetCurrentBranch(to: commit, mode: mode) }
    }
}

extension ResetMode {
    var title: String {
        switch self {
        case .soft: "Soft"
        case .mixed: "Mixed"
        case .hard: "Hard"
        }
    }

    var explanation: String {
        switch self {
        case .soft:
            "Moves the branch only. The changes of the commits that leave it stay staged, ready to commit again."
        case .mixed:
            "Moves the branch and unstages everything. The changes stay in the working copy's files."
        case .hard:
            "Moves the branch and makes every tracked file match the commit. Uncommitted changes to tracked files are discarded and cannot be recovered."
        }
    }
}
