import GitKit
import SwiftUI

/// The commits that changed a file, following it across renames, with the
/// selected commit's change to it below.
struct FileHistoryView: View {
    var model: RepositoryModel
    @State private var history: FileHistoryModel
    @State private var isCollapsed = false

    init(model: RepositoryModel, path: String, commitID: OID) {
        self.model = model
        _history = State(initialValue: FileHistoryModel(repository: model.repository, path: path, startID: commitID))
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $history.selection) {
                ForEach(history.entries) { entry in
                    FileHistoryRow(entry: entry, currentPath: history.path)
                        .tag(entry.id)
                }
                if !history.isComplete {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                        .task(id: history.entries.count) {
                            await run { try await history.loadMore() }
                        }
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 140, idealHeight: 240, maxHeight: 300)
            .overlay {
                if history.isComplete, history.entries.isEmpty {
                    ContentUnavailableView("No Commits", systemImage: "clock")
                }
            }
            Divider()
            diff
        }
        .navigationTitle(history.path.splitPath.name)
        .navigationSubtitle("History")
        .toolbar {
            if let entry = history.selectedEntry {
                ToolbarItem(placement: .primaryAction) {
                    Button("Show Commit", systemImage: "arrow.right.circle") {
                        model.showInHistory(entry.commit.id)
                    }
                    .help("Show this commit in the history")
                }
            }
        }
        .task {
            await run { try await history.start() }
        }
        .task(id: history.selection) {
            await run { try await history.loadDiff() }
        }
        .onDisappear {
            Task { await history.close() }
        }
    }

    @ViewBuilder
    private var diff: some View {
        if let entry = history.selectedEntry {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.commit.summary)
                            .font(.headline)
                        Text("\(entry.commit.author.name), \(entry.commit.author.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .textSelection(.enabled)
                    if let diff = history.diff, diff.path == entry.path || diff.oldPath == entry.path {
                        FileDiffView(file: diff, isCollapsed: $isCollapsed)
                    }
                }
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Commit Selected", systemImage: "smallcircle.filled.circle")
                .frame(maxHeight: .infinity)
        }
    }

    private func run(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            model.error = PresentedError(error)
        }
    }
}

private struct FileHistoryRow: View {
    var entry: FileHistoryEntry
    var currentPath: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            FileChangeBadge(change: entry.change)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.commit.summary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.commit.id.abbreviated())
                        .font(.smallCode)
                    Text(entry.commit.author.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(entry.commit.author.date, format: .dateTime.day().month(.defaultDigits).year(.twoDigits))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let oldPath = entry.oldPath {
                    Text("Renamed from \(oldPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if entry.path != currentPath {
                    Text("As \(entry.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
