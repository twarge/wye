import GitKit
import SwiftUI

/// The menu of the sidebar's Working Copy row, top to bottom: check out
/// something else, snapshot the changes, push and pull, throw changes away
/// or reset, bring in other work, compare, and find the folder.
struct WorkingCopyRowMenu: View {
    var model: RepositoryModel

    var body: some View {
        let branches = model.snapshot?.branches ?? []
        let isTransferring = model.isTransferring
        let current = model.currentBranch

        Menu("Check Out", systemImage: "arrow.uturn.down") {
            ForEach(branches) { branch in
                Button(branch.name) {
                    Task { await model.checkOutBranch(branch.id) }
                }
                .disabled(branch.isHead || branch.worktreePath != nil)
            }
            if !branches.isEmpty {
                Divider()
            }
            Button("Revision…") {
                model.present(.pickRevision(.checkOut))
            }
        }
        .disabled(model.isBusy)

        Section {
            Button("Create Snapshot…", systemImage: "camera") {
                model.present(.snapshot)
            }
            .disabled(model.workingCopy.entries.isEmpty || model.isBusy)
            .help("Keep a copy of the changes in a stash and leave them in place")
        }

        Section {
            if let current, current.upstream == nil {
                Button("Publish \(MenuNames.name(current.name))…", systemImage: "icloud.and.arrow.up") {
                    model.remotes.sheet = .pushTo(branch: current.id)
                }
                .disabled(!model.hasRemotes || isTransferring)
            } else {
                Button("Push", systemImage: "arrow.up") {
                    Task { await model.push() }
                }
                .disabled(isTransferring || current == nil || !model.hasRemotes)
            }
            Button("Push Revision To…", systemImage: "arrow.up.to.line") {
                model.present(.pickRevision(.pushRevision))
            }
            .disabled(!model.hasRemotes || isTransferring)
            Button("Pull…", systemImage: "arrow.down") {
                model.remotes.sheet = .pullOptions
            }
            .disabled(isTransferring || model.headBranchName == nil || !model.hasRemotes)
            if !model.hasRemotes {
                PublishMenuItems(model: model)
            }
        }

        Section {
            Button("Discard All Changes…", systemImage: "trash", role: .destructive) {
                model.showWorkingCopy(asking: .discardAllChanges)
            }
            .disabled(!model.workingCopy.hasUnstagedChanges)
            Button("Reset to Revision…", systemImage: "arrow.counterclockwise") {
                model.present(.pickRevision(.resetCurrentBranch))
            }
            .disabled(model.snapshot?.head.target == nil)
        }

        Section {
            Button("Merge With Revision…", systemImage: "arrow.triangle.merge") {
                model.present(.pickRevision(.merge))
            }
            .disabled(!model.canStartMerge)
            Button("Rebase On Revision…", systemImage: "arrow.triangle.pull") {
                model.present(.pickRevision(.rebase))
            }
            .disabled(!model.canStartMerge || model.headBranchName == nil)
            Button("Apply Patch…", systemImage: "doc.badge.plus") {
                model.history.requests.isImportingPatch = true
            }
            .disabled(model.isBusy)
        }

        Section {
            WorkingTreeCompareMenu(model: model)
        }

        Section {
            Button("Copy Path", systemImage: "doc.on.doc") {
                Platform.copyToClipboard(model.repository.url.path(percentEncoded: false))
            }
            .help("Copy the path of the repository’s folder")
            if Platform.canRevealFiles {
                Button(Platform.revealInFileBrowserTitle, systemImage: "folder") {
                    Platform.revealInFileBrowser(model.repository.url)
                }
            }
            Button("Repository Settings…", systemImage: "gearshape") {
                model.windowState.isShowingSettings = true
            }
        }
    }
}

/// Compare ▸ Working Tree to HEAD, Working Tree to Index, Index to HEAD.
struct WorkingTreeCompareMenu: View {
    var model: RepositoryModel?

    var body: some View {
        Menu("Compare", systemImage: "arrow.left.arrow.right") {
            ForEach(WorkingTreeComparison.allCases) { comparison in
                Button(comparison.title) {
                    model?.present(.compareWorkingTree(comparison))
                }
            }
        }
        .disabled(model?.snapshot == nil)
    }
}
