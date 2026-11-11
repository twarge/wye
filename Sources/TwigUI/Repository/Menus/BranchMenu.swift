import GitKit
import SwiftUI

/// The menu of a local branch in the sidebar, top to bottom: check it out,
/// bring it into the current branch, pin it, push it, choose what it
/// tracks, archive it, rename or delete it, start something from it, and
/// the items every reference has.
struct BranchMenu: View {
    var model: RepositoryModel
    var branch: Branch
    var marks: BranchListing.Marks
    var isArchived: Bool

    @Environment(\.openURL) private var openURL

    var body: some View {
        let id = branch.id
        let name = MenuNames.quoted(branch.name)
        let current = MenuNames.current(model)
        let interface = model.interface
        let isTransferring = model.isTransferring

        Section {
            Button("Check Out \(name)", systemImage: "arrow.uturn.down") {
                Task { await model.checkOutBranch(id) }
            }
            .disabled(branch.isHead || model.isBusy || branch.worktreePath != nil)
            Button("Check Out \(name) in New Worktree…", systemImage: "square.on.square") {
                model.nested.sheet = .addWorktree(.branch(id))
            }
            .disabled(branch.isHead || branch.worktreePath != nil)
        }

        Section {
            Button("Merge \(name) into \(current)…", systemImage: "arrow.triangle.merge") {
                model.present(.merge(id))
            }
            .disabled(branch.isHead || model.isBusy)
            Button("Rebase \(current) onto \(name)…", systemImage: "arrow.triangle.pull") {
                model.present(.rebase(onto: id))
            }
            .disabled(branch.isHead || model.isBusy || model.headBranchName == nil)
        }

        Section {
            if marks.isPinned {
                Button("Unpin \(name)", systemImage: "pin.slash") { interface.setPinned(id, false) }
            } else {
                Button("Pin \(name)", systemImage: "pin") { interface.setPinned(id, true) }
                    .help("Keep this branch at the top of the Branches section")
            }
        }

        Section {
            if branch.upstream == nil {
                Button("Publish \(name)…", systemImage: "icloud.and.arrow.up") {
                    model.remotes.sheet = .pushTo(branch: id)
                }
                .disabled(!model.hasRemotes || isTransferring)
            }
            Button("Push \(name) To…", systemImage: "arrow.up.to.line") {
                model.remotes.sheet = .pushTo(branch: id)
            }
            .disabled(!model.hasRemotes || isTransferring)
            Button("Force Push with Lease…", systemImage: "exclamationmark.arrow.triangle.2.circlepath") {
                model.present(.forcePushBranch(id))
            }
            .disabled(branch.upstream == nil || isTransferring)
            .help("Push even if commits on the remote branch are lost, unless it moved since the last fetch")
        }

        Section {
            UpstreamMenu(model: model, branch: branch)
        }

        Section {
            if isArchived {
                Button("Unarchive \(name)", systemImage: "archivebox") {
                    interface.unarchive(id, wasAutomatic: marks.isAutoArchived)
                }
                .help(marks.isAutoArchived
                      ? "Bring it back to the Branches section and stop archiving it automatically"
                      : "Bring it back to the Branches section")
            } else {
                Button("Archive \(name)", systemImage: "archivebox") { interface.setArchived(id, true) }
                    .disabled(branch.isHead)
                    .help("Move it to Archived Branches. The branch itself is not changed.")
            }
            Toggle("Never Archive Automatically", systemImage: "clock.badge.xmark", isOn: Binding {
                interface.skipsAutoArchiving(id)
            } set: {
                interface.setSkipsAutoArchiving(id, $0)
            })
            Toggle("Hide “Merged” Mark", systemImage: "checkmark.circle.badge.xmark", isOn: Binding {
                interface.hidesMergedMark(id)
            } set: {
                interface.setHidesMergedMark(id, $0)
            })
        }

        Section {
            Button("Rename \(name)…", systemImage: "pencil") {
                model.present(.renameBranch(id))
            }
            Button("Delete \(name)…", systemImage: "trash", role: .destructive) {
                model.present(.deleteBranch(id))
            }
            .disabled(branch.isHead || branch.worktreePath != nil)
        }

        Section {
            Button("New Branch from \(name)…", systemImage: "arrow.triangle.branch") {
                model.present(.newBranch(at: branch.target))
            }
            Button("New Tag on \(name)…", systemImage: "tag") {
                model.present(.newTag(at: branch.target))
            }
            PullRequestButton(
                title: "New Pull Request from \(name)…",
                url: model.pullRequestURL(forBranch: id),
                unavailable: model.pullRequestUnavailableReason(forBranch: id)
            )
        }

        ReferenceFooterItems(model: model, name: branch.name, target: branch.target, copyTitle: "Copy Branch Name")
    }
}

/// Which remote branch a local branch follows: Upstream Branch ▸ with
/// every remote branch, and Stop Tracking.
struct UpstreamMenu: View {
    var model: RepositoryModel
    var branch: Branch

    var body: some View {
        let upstream = branch.upstream?.name
        let candidates = (model.snapshot?.remotes.flatMap(\.branches) ?? []).filter { $0.nameWithoutRemote != "HEAD" }
        Menu("Upstream Branch", systemImage: "arrow.up.arrow.down") {
            ForEach(candidates) { candidate in
                Button {
                    Task { await model.setUpstream(of: branch.id, to: candidate.id) }
                } label: {
                    if candidate.name == upstream {
                        Label(candidate.name, systemImage: "checkmark")
                    } else {
                        Text(candidate.name)
                    }
                }
            }
            if !candidates.isEmpty {
                Divider()
            }
            Button("Stop Tracking") {
                Task { await model.setUpstream(of: branch.id, to: nil) }
            }
            .disabled(upstream == nil)
        }
    }
}

/// Opens the hosting service's page for a new pull request, or says why
/// it cannot.
struct PullRequestButton: View {
    var title: String
    var url: URL?
    var unavailable: String?

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(title, systemImage: "arrow.triangle.pull") {
            if let url { openURL(url) }
        }
        .disabled(url == nil)
        .help(unavailable ?? "Open the hosting service’s page for a new pull request")
    }
}
