import GitKit
import SwiftUI

/// The files at a commit, as an outline that reads each folder when it is
/// first opened.
struct TreeBrowserView: View {
    var model: RepositoryModel
    var commitID: OID

    @State private var root: [TreeEntry]?

    var body: some View {
        List {
            if let root {
                TreeLevel(model: model, commitID: commitID, entries: root)
            }
        }
        .overlay {
            if root == nil {
                ProgressView()
            } else if root?.isEmpty == true {
                ContentUnavailableView("No Files", systemImage: "folder")
            }
        }
        .task(id: commitID) {
            do {
                let entries = try await model.repository.treeEntries(in: commitID)
                guard !Task.isCancelled else { return }
                root = entries
            } catch {
                model.report(error)
            }
        }
    }
}

/// One folder's entries, folders first.
private struct TreeLevel: View {
    var model: RepositoryModel
    var commitID: OID
    var entries: [TreeEntry]

    var body: some View {
        ForEach(entries.sortedForBrowsing) { entry in
            if entry.isDirectory {
                TreeFolderRow(model: model, commitID: commitID, entry: entry)
            } else {
                TreeFileRow(commitID: commitID, entry: entry)
                    .fileDrag(entry.kind == .submodule ? nil : FileDrag(
                        repository: model.repository, path: entry.path, commit: commitID
                    ))
            }
        }
    }
}

private struct TreeFolderRow: View {
    var model: RepositoryModel
    var commitID: OID
    var entry: TreeEntry

    @State private var isExpanded = false
    @State private var children: [TreeEntry]?
    @Environment(\.openCommitRoute) private var open

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let children {
                TreeLevel(model: model, commitID: commitID, entries: children)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .task { await load() }
            }
        } label: {
            Label(entry.name, systemImage: "folder")
                .contextMenu {
                    Button("Show History", systemImage: "clock.arrow.circlepath") {
                        open(.fileHistory(path: entry.path, commit: commitID))
                    }
                }
        }
    }

    private func load() async {
        do {
            children = try await model.repository.treeEntries(in: commitID, at: entry.path)
        } catch {
            model.report(error)
        }
    }
}

private struct TreeFileRow: View {
    var commitID: OID
    var entry: TreeEntry

    @Environment(\.openCommitRoute) private var open

    var body: some View {
        if entry.kind == .submodule {
            Label {
                HStack {
                    Text(entry.name)
                    Spacer()
                    Text(entry.objectID.abbreviated())
                        .font(.smallCode)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "shippingbox")
            }
        } else {
            NavigationLink(value: CommitRoute.file(path: entry.path, commit: commitID)) {
                Label(entry.name, systemImage: icon)
            }
            .contextMenu {
                Button("Show History", systemImage: "clock.arrow.circlepath") {
                    open(.fileHistory(path: entry.path, commit: commitID))
                }
                Button("Blame", systemImage: "person.text.rectangle") {
                    open(.blame(path: entry.path, commit: commitID))
                }
            }
        }
    }

    private var icon: String {
        switch entry.kind {
        case .symlink: "arrow.turn.up.right"
        case .executable: "terminal"
        default: "doc"
        }
    }
}

private extension [TreeEntry] {
    var sortedForBrowsing: [TreeEntry] {
        sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}
