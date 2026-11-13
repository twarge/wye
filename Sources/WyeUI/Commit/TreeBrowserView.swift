import GitKit
import SwiftUI

/// What the list of a commit's files has chosen, to show beside it.
struct FileFocus: Hashable {
    var path: String
    /// A folder shows only its history.
    var isFolder = false
}

/// What shows of a file beside the list of files.
enum FileAspect: Hashable, CaseIterable {
    case contents
    case history
    case blame

    var title: LocalizedStringKey {
        switch self {
        case .contents: "Contents"
        case .history: "History"
        case .blame: "Blame"
        }
    }
}

/// A commit's files: on macOS the list on the left and, on the right, the
/// file chosen in it, its history or its blame, so nothing opens on top and
/// there is nothing to go back from; on iOS the list, a file opening on top
/// of it.
struct CommitFilesView: View {
    var model: RepositoryModel
    var commitID: OID
    @Binding var file: FileFocus?
    @Binding var aspect: FileAspect

    var body: some View {
        #if os(macOS)
        HSplitView {
            TreeBrowserView(model: model, commitID: commitID, selection: $file)
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 420)
            Group {
                if let file {
                    FilePane(model: model, commitID: commitID, file: file, aspect: $aspect)
                } else {
                    ContentUnavailableView("No File Selected", systemImage: "doc")
                }
            }
            .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        TreeBrowserView(model: model, commitID: commitID)
        #endif
    }
}

/// The right of a commit's files: a bar with the file's name and the choice
/// of its contents, history or blame, and that below it.
private struct FilePane: View {
    var model: RepositoryModel
    var commitID: OID
    var file: FileFocus
    @Binding var aspect: FileAspect

    var body: some View {
        let shown = file.isFolder ? .history : aspect
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(file.path.splitPath.name, systemImage: file.isFolder ? "folder" : "doc")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
                Spacer(minLength: 8)
                if !file.isFolder {
                    Picker("Show", selection: $aspect) {
                        ForEach(FileAspect.allCases, id: \.self) { aspect in
                            Text(aspect.title).tag(aspect)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            Group {
                switch shown {
                case .contents:
                    FileContentView(model: model, path: file.path, commitID: commitID, isBesideList: true)
                case .history:
                    FileHistoryView(model: model, path: file.path, commitID: commitID, isBesideList: true)
                case .blame:
                    BlameView(model: model, path: file.path, commitID: commitID, isBesideList: true)
                }
            }
            // Each file and view starts afresh.
            .id(PaneKey(file: file, aspect: shown, commitID: commitID))
        }
    }

    private struct PaneKey: Hashable {
        var file: FileFocus
        var aspect: FileAspect
        var commitID: OID
    }
}

/// The files at a commit, as an outline that reads each folder when it is
/// first opened. With a selection, choosing a file selects it; without, a
/// file opens on top.
struct TreeBrowserView: View {
    var model: RepositoryModel
    var commitID: OID
    var selection: Binding<FileFocus?>?

    @State private var root: [TreeEntry]?

    var body: some View {
        list
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

    @ViewBuilder
    private var list: some View {
        if let selection {
            List(selection: selection) { levels }
        } else {
            List { levels }
        }
    }

    @ViewBuilder
    private var levels: some View {
        if let root {
            TreeLevel(model: model, commitID: commitID, entries: root, select: selection.map { binding in
                { binding.wrappedValue = $0 }
            })
        }
    }
}

/// One folder's entries, folders first.
private struct TreeLevel: View {
    var model: RepositoryModel
    var commitID: OID
    var entries: [TreeEntry]
    /// Chooses an entry, where the list chooses rather than opens.
    var select: ((FileFocus) -> Void)?

    var body: some View {
        ForEach(entries.sortedForBrowsing) { entry in
            if entry.isDirectory {
                TreeFolderRow(model: model, commitID: commitID, entry: entry, select: select)
            } else {
                TreeFileRow(commitID: commitID, entry: entry, selects: select != nil)
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
    var select: ((FileFocus) -> Void)?

    @State private var isExpanded = false
    @State private var children: [TreeEntry]?
    @Environment(\.openCommitRoute) private var open

    var body: some View {
        // Chosen, where the list chooses, it shows its history beside it.
        if select != nil {
            disclosure.tag(focus)
        } else {
            disclosure
        }
    }

    private var disclosure: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let children {
                TreeLevel(model: model, commitID: commitID, entries: children, select: select)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .task { await load() }
            }
        } label: {
            Label(entry.name, systemImage: "folder")
                .contextMenu {
                    Button("Show History", systemImage: "clock.arrow.circlepath") {
                        if let select {
                            select(focus)
                        } else {
                            open(.fileHistory(path: entry.path, commit: commitID))
                        }
                    }
                }
        }
    }

    private var focus: FileFocus {
        FileFocus(path: entry.path, isFolder: true)
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
    var selects: Bool

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
            Group {
                if selects {
                    Label(entry.name, systemImage: icon)
                        .tag(FileFocus(path: entry.path))
                } else {
                    NavigationLink(value: CommitRoute.file(path: entry.path, commit: commitID)) {
                        Label(entry.name, systemImage: icon)
                    }
                }
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
