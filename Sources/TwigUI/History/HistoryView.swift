import GitKit
import SwiftUI

/// The list of commits for whatever the sidebar selects.
struct HistoryView: View {
    @Bindable var model: RepositoryModel
    @State private var isCreatingBranch = false
    @State private var isComparing = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var history = model.history
        @Bindable var search = history.search
        List(selection: $history.selection) {
            if search.isActive {
                // Matches are rarely next to each other, so the graph would
                // only mislead: results are plain rows in the history's order.
                ForEach(search.results) { commit in
                    SearchResultRow(commit: commit, labels: model.refLabels[commit.id] ?? [])
                        .tag(commit.id)
                        .commitActions(model: model, commit: commit)
                }
                if !search.isComplete {
                    SearchProgressRow(examined: search.examined)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                        .task(id: search.results.count) {
                            await search.loadMore()
                        }
                }
            } else {
                ForEach(history.items) { item in
                    switch item {
                    case .month(let date, _, let lines):
                        MonthRow(date: date, lines: lines, graphWidth: history.graphWidth)
                            .selectionDisabled()
                    case .commit(let row):
                        CommitRow(row: row, labels: model.refLabels[row.id] ?? [], graphWidth: history.graphWidth)
                            .tag(row.id)
                            .commitActions(model: model, commit: row.commit)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 14))
                .listRowSeparator(.hidden)

                if !history.isComplete, !history.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                        // Runs again as rows arrive, for as long as it stays on screen.
                        .task(id: history.items.count) {
                            await history.loadMore()
                        }
                }
            }
        }
        .listStyle(.plain)
        // Rows set their own height; a taller minimum would break the graph's lines.
        .environment(\.defaultMinListRowHeight, 1)
        .overlay {
            if search.isActive {
                if search.isComplete, search.results.isEmpty {
                    ContentUnavailableView.search(text: search.text)
                }
            } else if history.items.isEmpty, history.commitCount != nil {
                ContentUnavailableView("No Commits Yet", systemImage: "clock")
            }
        }
        .searchable(text: $search.text, prompt: search.field.prompt)
        .searchFocused($isSearchFocused)
        .task(id: model.viewRequests.pending) {
            // Find in History, from the menu bar.
            if model.viewRequests.take(.searchHistory) { isSearchFocused = true }
        }
        .searchScopes($search.field) {
            ForEach(HistoryQuery.Field.allCases) { field in
                Text(field.title).tag(field)
            }
        }
        .task(id: SearchKey(query: search.query, scope: history.scope, generation: history.generation)) {
            let query = search.query
            if !query.isEmpty {
                // Wait for a pause in typing before walking the history.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await search.search(query, in: history.scope)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("New Branch", systemImage: "plus") { isCreatingBranch = true }
                    .help("Create a branch at the selected commit")
                Button("Compare", systemImage: "arrow.left.arrow.right") { isComparing = true }
                    .help("Compare the selected commit with another commit, branch or tag")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .help("Read the repository again")
            }
        }
        .sheet(isPresented: $isCreatingBranch) {
            NewBranchSheet(model: model, startingPoint: history.selection)
        }
        .sheet(isPresented: $isComparing) {
            CompareView(model: model, base: history.selection)
        }
    }

    /// What a search depends on: it runs again when any of these changes.
    private struct SearchKey: Hashable {
        var query: HistoryQuery
        var scope: HistoryScope
        var generation: Int
    }

    private var title: String {
        switch model.selection {
        case .branch(let id): model.snapshot?.branches.first { $0.id == id }?.name ?? model.name
        case .remoteBranch(let id):
            model.snapshot?.remotes.flatMap(\.branches).first { $0.id == id }?.name ?? model.name
        case .tag(let id): model.snapshot?.tags.first { $0.id == id }?.name ?? model.name
        default: model.name
        }
    }

    private var subtitle: String {
        let search = model.history.search
        if search.isActive {
            let count = search.results.count
            let found = "\(count.formatted()) \(count == 1 ? "Result" : "Results")"
            return search.isComplete ? found : "Searching… (\(found))"
        }
        guard let count = model.history.commitCount else { return "History" }
        return "History (\(count.formatted()) \(count == 1 ? "Commit" : "Commits"))"
    }
}

private struct MonthRow: View {
    var date: Date
    var lines: [CommitGraph.Line]
    var graphWidth: Int

    var body: some View {
        Text(date, format: .dateTime.month(.wide).year())
            .font(.caption.weight(.medium))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.leading, GraphCell.width(forLanes: graphWidth) + 6)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                GraphCell(passing: lines, width: graphWidth)
            }
    }
}

private struct CommitRow: View {
    var row: HistoryModel.Row
    var labels: [RefLabel]
    var graphWidth: Int

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                VStack(alignment: .leading, spacing: 3) {
                    summary
                    HStack(spacing: 6) {
                        Text(row.commit.author.name)
                            .lineLimit(1)
                        hash
                        Spacer(minLength: 4)
                        date
                    }
                    .font(.caption)
                }
                .padding(.vertical, 7)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    hash
                    summary
                    Spacer(minLength: 8)
                    date
                }
                .padding(.vertical, 5)
            }
        }
        .padding(.leading, GraphCell.width(forLanes: graphWidth) + 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            GraphCell(row: row.graph, width: graphWidth)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: some View {
        HStack(spacing: 4) {
            ForEach(labels) { label in
                RefBadge(label: label)
                    .fixedSize()
            }
            Text(row.commit.summary)
                .lineLimit(1)
        }
    }

    private var hash: some View {
        Text(row.commit.id.abbreviated())
            .font(.smallCode)
            .foregroundStyle(.secondary)
    }

    private var date: some View {
        Text(row.commit.author.date, format: .dateTime.day().month(.defaultDigits).year(.twoDigits))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// Asks for a new branch's name.
struct NewBranchSheet: View {
    var model: RepositoryModel
    /// The commit to branch from; `HEAD` when `nil`.
    var startingPoint: OID?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var checksOut = true

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                LabeledContent("Starting Point") {
                    Text(startingPoint?.abbreviated() ?? "HEAD")
                        .font(.code)
                }
                Toggle("Check Out", isOn: $checksOut)
            }
            .formStyle(.grouped)
            .navigationTitle("New Branch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 360)
    }

    private func create() {
        let name = name.trimmingCharacters(in: .whitespaces)
        let checksOut = checksOut
        let startingPoint = startingPoint
        dismiss()
        Task {
            await model.perform { repository in
                let branch = try await repository.createBranch(named: name, at: startingPoint)
                if checksOut {
                    try await repository.checkOut(branch: branch)
                }
            }
        }
    }
}
