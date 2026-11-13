import GitKit
import SwiftUI

/// A submodule in the sidebar: its path, and its state when it needs
/// attention.
struct SubmoduleLabel: View {
    var submodule: Submodule

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(submodule.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if submodule.status != .upToDate {
                    Image(systemName: submodule.status.systemImage)
                        .foregroundStyle(submodule.status == .missing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityLabel(submodule.status.title)
                }
            }
        } icon: {
            Image(systemName: "shippingbox")
        }
        .help("\(submodule.path): \(submodule.status.title)")
    }
}

/// The actions on one submodule, for its context menu and its detail.
struct SubmoduleActions: View {
    var model: RepositoryModel
    var submodule: Submodule

    var body: some View {
        let name = submodule.name
        let busy = model.isTransferring
        Button("Open", systemImage: "arrow.up.forward.app") {
            model.nested.opening = .submodule(name)
        }
        .disabled(!submodule.status.isCloned)
        Button("Check Out Revision…", systemImage: "arrow.uturn.down") {
            model.nested.sheet = .checkOutSubmodule(name)
        }
        .disabled(!submodule.status.isCloned)
        Divider()
        Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
            Task { await model.fetchSubmodules([name]) }
        }
        .disabled(busy || !submodule.status.isCloned)
        Button("Update", systemImage: "arrow.down.circle") {
            Task { await model.updateSubmodules([name]) }
        }
        .disabled(busy)
        Button("Initialize", systemImage: "circle.dashed") {
            Task { await model.initializeSubmodules([name]) }
        }
        .disabled(submodule.status != .notInitialized)
        Button("Synchronize URL", systemImage: "link") {
            Task { await model.synchronizeSubmodules([name]) }
        }
        .disabled(submodule.status == .notInitialized)
        Divider()
        // Moving is git's rename too: a submodule's name in .gitmodules
        // has no command of its own to change it.
        Button("Move…", systemImage: "folder") {
            model.nested.sheet = .moveSubmodule(name)
        }
        Button("Change URL…", systemImage: "pencil") {
            model.nested.sheet = .changeSubmoduleURL(name)
        }
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive) {
            model.nested.sheet = .removeSubmodule(name)
        }
    }
}

/// The actions on all submodules at once, for the sidebar's section and
/// the Repository menu.
struct AllSubmodulesActions: View {
    var model: RepositoryModel?

    var body: some View {
        let busy = model?.isTransferring ?? true
        Button("Add Submodule…", systemImage: "plus") {
            model?.nested.sheet = .addSubmodule
        }
        .disabled(model == nil || model?.repository.isBare == true)
        Button("Update All Submodules", systemImage: "arrow.down.circle") {
            Task { await model?.updateSubmodules() }
        }
        .disabled(busy || model?.hasSubmodules != true)
        Button("Fetch All Submodules", systemImage: "arrow.triangle.2.circlepath") {
            Task { await model?.fetchSubmodules() }
        }
        .disabled(busy || model?.hasSubmodules != true)
    }
}


