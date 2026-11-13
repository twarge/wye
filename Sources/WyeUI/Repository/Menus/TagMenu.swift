import GitKit
import SwiftUI

/// The menu of a tag in the sidebar, top to bottom: check it out or branch
/// from it, push it, delete it here or on a remote, and the items every
/// reference has.
struct TagMenu: View {
    var model: RepositoryModel
    var tag: Tag

    var body: some View {
        let remotes = model.remoteNames
        let isTransferring = model.isTransferring

        Section {
            Button("Check Out", systemImage: "arrow.uturn.down") {
                Task { await model.checkOutTag(tag.id) }
            }
            .disabled(model.isBusy)
            .help("Check out the tag’s commit with HEAD detached")
            Button("New Branch from Here…", systemImage: "arrow.triangle.branch") {
                model.present(.newBranch(at: tag.target))
            }
        }

        Section {
            if remotes.count == 1, let remote = remotes.first {
                Button("Push to \(MenuNames.name(remote))", systemImage: "arrow.up") {
                    Task { await model.pushTag(tag.id, to: remote) }
                }
                .disabled(isTransferring)
            } else if !remotes.isEmpty {
                Menu("Push To", systemImage: "arrow.up") {
                    ForEach(remotes, id: \.self) { remote in
                        Button(remote) { Task { await model.pushTag(tag.id, to: remote) } }
                    }
                }
                .disabled(isTransferring)
            }
        }

        Section {
            Button("Delete…", systemImage: "trash", role: .destructive) {
                model.present(.deleteTag(tag.id))
            }
            Button("Delete from Remote…", systemImage: "trash", role: .destructive) {
                model.remotes.sheet = .deleteRemoteTag(tag.id)
            }
            .disabled(remotes.isEmpty || isTransferring)
        }

        ReferenceFooterItems(model: model, name: tag.name, target: tag.target, copyTitle: "Copy Tag Name")
    }
}
