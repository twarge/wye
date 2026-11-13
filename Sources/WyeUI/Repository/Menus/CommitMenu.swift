import GitKit
import SwiftUI

/// The menu of one commit in a history, top to bottom: the menus of the
/// branches and tags at it, copy it, check it out, merge it into the
/// current branch or rebase that onto it, move the current branch to it or
/// take its changes, name it, write it out or compare it, and open it on
/// the web.
struct CommitActionsMenu: View {
    var model: RepositoryModel
    var commit: Commit

    @Environment(\.openURL) private var openURL
    @Environment(\.openCommitWindow) private var openCommitWindow

    var body: some View {
        let requests = model.history.requests
        ReferenceSubmenus(model: model, commit: commit)

        if let openCommitWindow {
            Section {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { openCommitWindow(commit.id) }
                    .help("Show this commit in a window of its own; double-click it to do the same")
            }
        }

        Section {
            Button("Copy Hash", systemImage: "doc.on.doc") {
                Platform.copyToClipboard(commit.id.hex)
            }
            #if os(macOS)
            // What Copy does in the history, shown here; see HistoryView.
            .keyboardShortcut("c")
            #endif
            Button("Copy Commit Info", systemImage: "info.circle") {
                Platform.copyToClipboard(commit.info)
            }
            // Where the list is not the full history: a search's results.
            if model.history.search.isActive || model.history.scope != .allReferences {
                Button("Reveal in History", systemImage: "scope") {
                    Task { await model.revealInFullHistory(commit.id) }
                }
            }
        }

        Section {
            Button("Check Out", systemImage: "arrow.uturn.down") {
                Task { await model.checkOutCommit(commit.id) }
            }
            .disabled(isHead)
            .help("Check out this commit with HEAD detached")
        }

        Section {
            let revision = branchingRevision
            let current = MenuNames.current(model)
            Button("Merge into \(current)…", systemImage: "arrow.triangle.merge") {
                model.present(.merge(revision))
            }
            .disabled(isHead || model.isBusy)
            Button("Rebase \(current) onto Here…", systemImage: "arrow.triangle.pull") {
                model.present(.rebase(onto: revision))
            }
            .disabled(isHead || model.isBusy || model.headBranchName == nil)
            .help("Replay the current branch’s commits on top of this commit")
            Button("Rebase \(current) Interactively onto Here…", systemImage: "list.number") {
                model.rebasing.interactive = .onto(commit.id)
            }
            .disabled(isHead || model.isBusy || !model.canStartMerge)
            .help("Choose which of the current branch’s commits to replay on top of this commit, and how")
        }

        Section {
            Button("Reset \(MenuNames.current(model)) to Here…", systemImage: "arrow.counterclockwise") {
                model.present(.reset(to: commit.id))
            }
            .disabled(isHead || model.snapshot?.head.target == nil)
            Button("Revert", systemImage: "arrow.uturn.backward") {
                Task { await model.revert([commit.id]) }
            }
            .disabled(model.isBusy)
            .help("Make a new commit that undoes this one’s changes")
            Button("Cherry-Pick", systemImage: "arrow.down.to.line") {
                Task { await model.cherryPick([commit.id]) }
            }
            .disabled(isHead || model.isBusy)
            .help("Apply this commit’s changes on top of HEAD")
            if isHead {
                Button("Edit Message…", systemImage: "pencil") {
                    requests.reword = commit
                }
                .disabled(model.isBusy)
            }
        }

        RebaseCommitItems(model: model, commit: commit)

        Section {
            Button("New Branch from Here…", systemImage: "arrow.triangle.branch") {
                model.present(.newBranch(at: commit.id))
            }
            Button("New Tag Here…", systemImage: "tag") {
                model.present(.newTag(at: commit.id))
            }
        }

        CommitNoteMenuItems(model: model, commit: commit)

        Section {
            Button("Save as Patch…", systemImage: "square.and.arrow.down") {
                Task { await requests.export(commit, from: model) }
            }
            .disabled(commit.isMerge)
            if !commit.isMerge {
                ShareLink(
                    "Share Patch…",
                    item: CommitDrag(repository: model.repository, commits: [commit]),
                    preview: SharePreview(commit.summary, icon: Image(systemName: "doc.badge.gearshape"))
                )
            }
            Button("Export Files from Here…", systemImage: "archivebox") {
                Task { await model.exportFiles(of: commit.id, named: commit.id.abbreviated()) }
            }
            .help("Save the files at this commit as a zip archive")
            Button("Compare With…", systemImage: "arrow.left.arrow.right") {
                model.present(.pickRevision(.compare(commit.id.abbreviated())))
            }
            Button("Compare With Local Changes", systemImage: "arrow.left.arrow.right.square") {
                model.present(.compareLocalChanges(to: commit.id))
            }
            .help("Show how the working tree, staged or not, differs from this commit")
            Button("Apply Patch…", systemImage: "doc.badge.plus") {
                requests.isImportingPatch = true
            }
            .disabled(model.isBusy)
        }

        if let url = model.webURL(forCommit: commit.id) {
            Section {
                Button("Open on Web", systemImage: "safari") { openURL(url) }
                ShareLink("Share Link…", item: url, subject: Text(commit.summary))
            }
        }
    }

    private var isHead: Bool {
        model.snapshot?.head.target == commit.id
    }

    /// What Merge and Rebase are given: the one local branch at this
    /// commit, or else the one remote branch, so a merge commit's message
    /// names the branch as git's would; otherwise the commit itself.
    private var branchingRevision: String {
        let snapshot = model.snapshot
        let local = snapshot?.branches.filter { $0.target == commit.id && !$0.isHead } ?? []
        let remote = snapshot?.remotes.flatMap(\.branches)
            .filter { $0.target == commit.id && $0.nameWithoutRemote != "HEAD" } ?? []
        if let branch = local.count == 1 ? local.first : local.isEmpty && remote.count == 1 ? remote.first : nil {
            return branch.id
        }
        return commit.id.hex
    }
}

/// A submenu for each branch, remote branch and tag at a commit, holding
/// the menu the sidebar gives it.
private struct ReferenceSubmenus: View {
    var model: RepositoryModel
    var commit: Commit

    var body: some View {
        let snapshot = model.snapshot
        let branches = snapshot?.branches.filter { $0.target == commit.id } ?? []
        let remoteBranches = snapshot?.remotes.flatMap(\.branches)
            .filter { $0.target == commit.id && $0.nameWithoutRemote != "HEAD" } ?? []
        let tags = snapshot?.tags.filter { $0.target == commit.id } ?? []
        if !branches.isEmpty || !remoteBranches.isEmpty || !tags.isEmpty {
            let listing = model.branchListing(
                staleMonths: BranchPreferences.staleMonths, autoArchiveMonths: BranchPreferences.autoArchiveMonths
            )
            Section {
                ForEach(branches) { branch in
                    Menu(branch.name, systemImage: "arrow.triangle.branch") {
                        BranchMenu(
                            model: model, branch: branch, marks: listing.marks[branch.id] ?? .init(),
                            isArchived: listing.archived.contains { $0.id == branch.id }
                        )
                    }
                }
                ForEach(remoteBranches) { branch in
                    Menu(branch.name, systemImage: "cloud") {
                        RemoteBranchMenu(model: model, branch: branch)
                    }
                }
                ForEach(tags) { tag in
                    Menu(tag.name, systemImage: "tag") {
                        TagMenu(model: model, tag: tag)
                    }
                }
            }
        }
    }
}

/// The menu of several commits selected together, in the order the
/// history lists them: newest first.
struct MultipleCommitsMenu: View {
    var model: RepositoryModel
    var commits: [Commit]

    var body: some View {
        let count = commits.count
        Button("Cherry-Pick \(count) Commits", systemImage: "arrow.down.to.line") {
            Task { await model.cherryPick(commits.map(\.id)) }
        }
        .disabled(model.isBusy || commits.contains { $0.id == model.snapshot?.head.target })
        .help("Apply their changes on top of HEAD, oldest first")
        Button("Revert \(count) Commits", systemImage: "arrow.uturn.backward") {
            Task { await model.revert(commits.map(\.id)) }
        }
        .disabled(model.isBusy)
        .help("Undo their changes, newest first, one commit each")

        Divider()

        Button("Compare First and Last", systemImage: "arrow.left.arrow.right") {
            if let oldest = commits.last, let newest = commits.first {
                model.history.requests.compare = CompareRequest(from: oldest.id.hex, to: newest.id.hex)
            }
        }
        .help("Compare the oldest selected commit with the newest")

        Divider()

        Button("Copy Hashes", systemImage: "doc.on.doc") {
            Platform.copyToClipboard(commits.map(\.id.hex).joined(separator: "\n"))
        }
        Button("Copy Commit Info", systemImage: "info.circle") {
            Platform.copyToClipboard(commits.map(\.info).joined(separator: "\n\n"))
        }
    }
}
