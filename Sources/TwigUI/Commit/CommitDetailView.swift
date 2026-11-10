import GitKit
import SwiftUI

/// A commit's details and what it changed, or the files it holds. A file's
/// history, its blame and the file itself open on top of it.
struct CommitDetailView: View {
    var model: RepositoryModel
    var commitID: OID?
    var emptyTitle: LocalizedStringKey = "No Commit Selected"

    @State private var path: [CommitRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            CommitDetailContent(model: model, commitID: commitID, emptyTitle: emptyTitle)
                .navigationDestination(for: CommitRoute.self) { $0.destination(model) }
        }
        .environment(\.openCommitRoute, OpenCommitRouteAction { path.append($0) })
        // What was opened for one commit does not stay over the next.
        .onChange(of: commitID) {
            path = []
        }
    }
}

private struct CommitDetailContent: View {
    var model: RepositoryModel
    var commitID: OID?
    var emptyTitle: LocalizedStringKey

    @Environment(\.openCommitRoute) private var open
    @State private var loaded: Loaded?
    @State private var collapsed: Set<String> = []
    @State private var mode = Mode.changes
    /// The parent a merge is compared with, remembered for that merge only.
    @State private var parentChoice: (commit: OID, index: Int)?

    private enum Mode: Hashable {
        case changes
        case files
    }

    private struct Loaded {
        var commit: Commit
        var parentIndex: Int
        var files: [FileDiff]
    }

    private struct LoadKey: Hashable {
        var commitID: OID?
        var parentIndex: Int
        var diffOptions: DiffOptions
    }

    private var parentIndex: Int {
        guard let parentChoice, parentChoice.commit == commitID else { return 0 }
        return parentChoice.index
    }

    var body: some View {
        Group {
            if let loaded, loaded.commit.id == commitID {
                VStack(spacing: 0) {
                    Picker("Show", selection: $mode) {
                        Text("Changes").tag(Mode.changes)
                        Text("Files").tag(Mode.files)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    Divider()
                    switch mode {
                    case .changes:
                        changes(loaded)
                    case .files:
                        TreeBrowserView(model: model, commitID: loaded.commit.id)
                    }
                }
            } else if commitID == nil {
                ContentUnavailableView(emptyTitle, systemImage: "smallcircle.filled.circle")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: LoadKey(commitID: commitID, parentIndex: parentIndex, diffOptions: DiffPreferences.shared.options)) {
            await load()
        }
    }

    private func changes(_ loaded: Loaded) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                CommitHeader(commit: loaded.commit, labels: model.refLabels[loaded.commit.id] ?? []) {
                    model.history.selection = $0
                }
                .textSelection(.enabled)
                Divider()
                message(of: loaded.commit)
                    .textSelection(.enabled)
                if loaded.commit.isMerge {
                    parentPicker(loaded.commit)
                }
                changesSummary(loaded.files)
                ForEach(loaded.files) { file in
                    FileDiffView(
                        file: file,
                        isCollapsed: isCollapsed(file.id),
                        fileActions: FileActions(for: file, in: loaded.commit.id, open: open)
                            .adding(workingCopyCommandsFor: file, in: loaded.commit.id, model: model)
                    )
                }
            }
            .padding(.bottom, 20)
        }
    }

    /// A merge has a diff against each parent; this chooses which one.
    private func parentPicker(_ commit: Commit) -> some View {
        Picker("Compared with", selection: Binding {
            parentIndex
        } set: { index in
            parentChoice = (commit.id, index)
        }) {
            ForEach(commit.parentIDs.indices, id: \.self) { index in
                Text("Parent \(index + 1) (\(commit.parentIDs[index].abbreviated()))")
                    .tag(index)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func load() async {
        guard let commitID else {
            loaded = nil
            return
        }
        let parentIndex = parentIndex
        do {
            let commit = try await model.repository.commit(commitID)
            let files = try await model.repository.changes(in: commitID, parent: parentIndex, options: DiffPreferences.shared.options)
            guard !Task.isCancelled else { return }
            if loaded?.commit.id != commitID {
                collapsed = DiffPreferences.shared.initiallyCollapsed(files)
            }
            loaded = Loaded(commit: commit, parentIndex: parentIndex, files: files)
        } catch {
            model.error = PresentedError(error)
        }
    }

    private func message(of commit: Commit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.summary)
                .font(.headline)
            if !commit.body.isEmpty {
                Text(commit.body)
                    .font(.body)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changesSummary(_ files: [FileDiff]) -> some View {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        return HStack {
            Button(collapsed.isEmpty ? "Collapse All" : "Expand All") {
                collapsed = collapsed.isEmpty ? Set(files.map(\.id)) : []
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            Spacer(minLength: 12)
            Text(
                "\(counted(files.count, "changed file")) with \(counted(additions, "addition")) and \(counted(deletions, "deletion"))"
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func counted(_ count: Int, _ noun: String) -> String {
        "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
    }

    private func isCollapsed(_ id: String) -> Binding<Bool> {
        Binding {
            collapsed.contains(id)
        } set: { isCollapsed in
            if isCollapsed {
                collapsed.insert(id)
            } else {
                collapsed.remove(id)
            }
        }
    }
}

private struct CommitHeader: View {
    var commit: Commit
    var labels: [RefLabel]
    var showCommit: (OID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                row("Author") { Text(commit.author.nameAndEmail) }
                row("Author Date") { date(commit.author.date) }
                row("Committer") { Text(commit.committer.nameAndEmail) }
                row("Committer Date") { date(commit.committer.date) }
                if !labels.isEmpty {
                    row("Refs") {
                        HStack(spacing: 4) {
                            ForEach(labels) { RefBadge(label: $0) }
                        }
                    }
                }
                row("Commit Hash") { hash(commit.id) }
                if !commit.parentIDs.isEmpty {
                    row(commit.parentIDs.count == 1 ? "Parent Hash" : "Parent Hashes") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(commit.parentIDs, id: \.self) { parent in
                                Button {
                                    showCommit(parent)
                                } label: {
                                    hash(parent)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                                .help("Show this commit")
                            }
                        }
                    }
                }
                row("Tree Hash") { hash(commit.treeID) }
            }
            .font(.callout)
            Spacer(minLength: 0)
            Text(commit.author.initials)
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(.fill.secondary, in: .circle)
                .accessibilityHidden(true)
        }
        .padding(16)
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
        }
    }

    private func date(_ date: Date) -> some View {
        Text(date, format: Date.FormatStyle(date: .long, time: .complete))
    }

    private func hash(_ id: OID) -> some View {
        Text(id.hex)
            .font(.code)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
