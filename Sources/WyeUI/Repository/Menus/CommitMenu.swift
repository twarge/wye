import GitKit
import SwiftUI

/// The menu of one commit in a history, top to bottom: copy it, check it
/// out, move the current branch to it or take its changes, name it, write
/// it out or compare it, and open it on the web.
struct CommitActionsMenu: View {
    var model: RepositoryModel
    var commit: Commit

    @Environment(\.openURL) private var openURL

    var body: some View {
        let requests = model.history.requests
        let hash = MenuNames.quoted(commit.id)
        Section {
            Button("Copy Hash", systemImage: "doc.on.doc") {
                Platform.copyToClipboard(commit.id.hex)
            }
            Button("Copy Commit Info", systemImage: "info.circle") {
                Platform.copyToClipboard(commit.info)
            }
            // Where the list is not the full history: a search, or one
            // branch's or tag's history.
            if model.history.search.isActive || model.selection != .history {
                Button("Reveal in History", systemImage: "scope") {
                    Task { await model.revealInFullHistory(commit.id) }
                }
            }
        }

        Section {
            Button("Check Out \(hash)", systemImage: "arrow.uturn.down") {
                Task { await model.checkOutCommit(commit.id) }
            }
            .disabled(isHead)
            .help("Check out this commit with HEAD detached")
        }

        Section {
            Button("Reset \(MenuNames.current(model)) to \(hash)…", systemImage: "arrow.counterclockwise") {
                model.present(.reset(to: commit.id))
            }
            .disabled(isHead || model.snapshot?.head.target == nil)
            Button("Revert \(hash)", systemImage: "arrow.uturn.backward") {
                Task { await model.revert([commit.id]) }
            }
            .disabled(model.isBusy)
            .help("Make a new commit that undoes this one’s changes")
            Button("Cherry-Pick \(hash)", systemImage: "arrow.down.to.line") {
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
            Button("New Branch from \(hash)…", systemImage: "arrow.triangle.branch") {
                model.present(.newBranch(at: commit.id))
            }
            Button("New Tag on \(hash)…", systemImage: "tag") {
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
            Button("Export Files from \(hash)…", systemImage: "archivebox") {
                Task { await model.exportFiles(of: commit.id, named: commit.id.abbreviated()) }
            }
            .help("Save the files at this commit as a zip archive")
            Button("Compare \(hash) With…", systemImage: "arrow.left.arrow.right") {
                model.present(.pickRevision(.compare(commit.id.abbreviated())))
            }
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
