import GitKit
import SwiftUI
import TipKit

/// The list of commits for whatever the sidebar selects.
struct HistoryView: View {
    @Bindable var model: RepositoryModel
    @State private var isCreatingBranch = false
    @FocusState private var isSearchFocused: Bool
    @Environment(\.openCommitWindow) private var openCommitWindow
    /// Compact, rows are on two lines and have no columns to name.
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var preferences: HistoryPreferences { .shared }

    var body: some View {
        @Bindable var history = model.history
        @Bindable var search = history.search
        ScrollViewReader { proxy in
            List(selection: $history.listSelection) {
                TipView(DragCommitTip())
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                if search.isActive {
                    // Matches are rarely next to each other, so the graph would
                    // only mislead: results are plain rows in the history's order.
                    ForEach(search.results) { commit in
                        SearchResultRow(commit: commit, labels: model.refLabels[commit.id] ?? [],
                                        columns: preferences.columns,
                                        isHead: commit.id == headID, hasNote: history.notes.hasNote(commit.id))
                            .tag(commit.id)
                            .draggable(drag(for: commit))
                    }
                    if !search.isComplete {
                        SearchProgressRow(examined: search.examined)
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                            .task(id: search.results.count) {
                                await search.loadMore()
                            }
                    }
                } else if sizeClass != .compact {
                    // The header stays at the top as the rows scroll under it.
                    Section {
                        commitRows(history)
                    } header: {
                        HistoryColumnHeader(columns: preferences.columns, leading: rowLeading)
                            .textCase(nil)
                            #if os(macOS)
                            // A section header takes no row insets on the
                            // Mac, though it has the rows' margins: as padding.
                            .padding(.leading, Self.rowInsets.leading)
                            .padding(.trailing, Self.rowInsets.trailing)
                            #else
                            .listRowInsets(Self.rowInsets)
                            #endif
                    }
                } else {
                    commitRows(history)
                }
            }
            #if os(macOS)
            .contextMenu(forSelectionType: OID.self) { ids in
                selectionMenu(ids)
            } primaryAction: { ids in
                // A double-click: the commit in a window of its own.
                if ids.count == 1, let id = ids.first { openCommitWindow?(id) }
            }
            #else
            // A primary action here would take over a tap, which selects.
            .contextMenu(forSelectionType: OID.self) { ids in
                selectionMenu(ids)
            }
            #endif
            // The window follows changes on disk; iOS sees only some of them.
            .refreshable { await model.refresh() }
            #if os(macOS)
            // Edit ▸ Copy while the list has focus: the selected commits' hashes.
            .copyable(copiedHashes)
            #endif
            .onChange(of: history.scrollTarget) {
                guard let target = history.scrollTarget else { return }
                withMotion {
                    proxy.scrollTo(HistoryModel.Item.ID.commit(target), anchor: .center)
                }
                history.didScroll()
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
                if search.filters.isEmpty {
                    ContentUnavailableView("No Commits Yet", systemImage: "clock")
                } else {
                    ContentUnavailableView("No Commits on These Branches", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .searchable(text: $search.text, tokens: Binding {
            search.filters.tokens
        } set: { tokens in
            search.filters = search.filters.keeping(tokens)
        }, prompt: search.field.prompt) { token in
            Label(token.title, systemImage: token.systemImage)
        }
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
        .task(id: SearchKey(query: search.query, filter: search.filters.commitFilter, scope: history.scope,
                            generation: history.generation)) {
            let query = search.query
            if !query.isEmpty {
                // Wait for a pause in typing before walking the history.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await search.search(query, filter: search.filters.commitFilter, in: history.scope, options: history.options)
        }
        .task(id: LayoutKey(layout: preferences.layout, shown: search.filters.shownBranches,
                            hidden: search.filters.hiddenBranches)) {
            await history.apply(preferences.layout, filters: search.filters)
        }
        // A branch or tag shows the full history too, with its commit selected.
        .navigationTitle(model.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if history.multipleSelection.count > 1 {
                    Menu("\(history.multipleSelection.count) Selected", systemImage: "checklist") {
                        MultipleCommitsMenu(model: model, commits: history.commits(history.multipleSelection))
                    }
                    .help("Act on the selected commits")
                }
                Button("New Branch", image: .branch) { isCreatingBranch = true }
                    .help("Create a branch at the selected commit")
                // Filter and the view options are in the More menu.
            }
            if Platform.selectsSeveralInEditMode {
                ToolbarItem(placement: .primaryAction) {
                    SelectionModeButton()
                }
            }
        }
        .sheet(isPresented: $isCreatingBranch) {
            NewBranchSheet(model: model, startingPoint: history.selection)
        }
        .historyFilterSheets(search)
    }

    /// The history's rows: its headings and commits, and a spinner while
    /// more are read.
    @ViewBuilder
    private func commitRows(_ history: HistoryModel) -> some View {
        ForEach(history.items) { item in
            switch item {
            case .heading(let date, let grouping, _, let lines):
                HeadingRow(date: date, grouping: grouping, lines: lines, graphWidth: graphWidth)
                    .selectionDisabled()
            case .commit(let row):
                CommitRow(row: row, labels: model.refLabels[row.id] ?? [], graphWidth: graphWidth,
                          showsGraph: preferences.showsGraph, columns: preferences.columns,
                          widths: preferences.columnWidths, size: rowSize,
                          isHead: row.id == headID, hasNote: history.notes.hasNote(row.id)) {
                    Task { await history.toggleFold(of: row.id) }
                }
                    .tag(row.id)
                    // Onto a branch in the sidebar, to cherry-pick.
                    .draggable(drag(for: row.commit))
            }
        }
        .listRowInsets(Self.rowInsets)
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

    /// The rows' insets, which the column header shares so its titles
    /// stand over their columns.
    private static let rowInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 14)

    /// Where a row's text starts: after the graph and a gap.
    private var rowLeading: CGFloat {
        preferences.showsGraph ? GraphCell.width(forLanes: graphWidth) + 6 : 0
    }

    /// The context menu for the commits it was opened on: one commit's
    /// actions, or those for several, then what the rows show. Opened on
    /// no commit, it has all the ways the history is shown.
    @ViewBuilder
    private func selectionMenu(_ ids: Set<OID>) -> some View {
        let commits = model.history.commits(ids)
        if commits.count == 1, let commit = commits.first {
            CommitActionsMenu(model: model, commit: commit)
            Section {
                HistoryRowOptions()
                HistoryGroupingPicker()
            }
        } else if commits.count > 1 {
            MultipleCommitsMenu(model: model, commits: commits)
            Section {
                HistoryRowOptions()
                HistoryGroupingPicker()
            }
        } else {
            HistoryViewOptions()
        }
    }

    /// What Copy puts on the clipboard: the selected commits' hashes, a line
    /// each, newest first, as Copy Hashes does.
    private var copiedHashes: [String] {
        let commits = model.history.commits(model.history.listSelection)
        return commits.isEmpty ? [] : [commits.map(\.id.hex).joined(separator: "\n")]
    }

    private var graphWidth: Int {
        preferences.showsGraph ? model.history.graphWidth : 0
    }

    private var rowSize: HistoryPreferences.RowSize {
        Platform.choosesHistoryRowSize ? preferences.rowSize : .regular
    }

    /// What a search depends on: it runs again when any of these changes.
    private struct SearchKey: Hashable {
        var query: HistoryQuery
        var filter: HistoryFilter
        var scope: HistoryScope
        var generation: Int
    }

    /// What the history's walk depends on beyond its scope.
    private struct LayoutKey: Hashable {
        var layout: HistoryLayout
        var shown: [String]
        var hidden: [String]
    }

    private var headID: OID? { model.snapshot?.head.target }

    /// A dragged commit carries the whole selection when it is part of it:
    /// hashes for the sidebar, a patch file for anywhere outside the window.
    private func drag(for commit: Commit) -> CommitDrag {
        let selected = model.history.listSelection
        guard selected.count > 1, selected.contains(commit.id) else {
            return CommitDrag(repository: model.repository, commits: [commit])
        }
        return CommitDrag(repository: model.repository, commits: model.history.commits(selected))
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

private struct HeadingRow: View {
    var date: Date
    var grouping: HistoryPreferences.Grouping
    var lines: [CommitGraph.Line]
    var graphWidth: Int

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.leading, graphWidth > 0 ? GraphCell.width(forLanes: graphWidth) + 6 : 0)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                if graphWidth > 0 {
                    GraphCell(passing: lines, width: graphWidth)
                }
            }
    }

    private var title: String {
        switch grouping {
        case .day:
            date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            "Week of " + (Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start ?? date)
                .formatted(.dateTime.day().month(.wide).year())
        case .month, .none:
            date.formatted(.dateTime.month(.wide).year())
        }
    }
}

private struct CommitRow: View {
    var row: HistoryModel.Row
    var labels: [RefLabel]
    var graphWidth: Int
    var showsGraph: Bool
    var columns: HistoryColumns
    var widths: HistoryColumnWidths
    var size: HistoryPreferences.RowSize
    /// `HEAD`'s commit is bold, in place of a badge.
    var isHead = false
    var hasNote = false
    /// Folds or unfolds the branch a merge brought in.
    var toggleFold: () -> Void = {}

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                VStack(alignment: .leading, spacing: 3) {
                    summary
                    HStack(spacing: 6) {
                        author
                        if columns.hash { hash }
                        Spacer(minLength: 4)
                        if columns.date { date }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 7)
            } else {
                // The columns the header names, as wide as it has them.
                HStack(alignment: .firstTextBaseline, spacing: HistoryColumnWidths.spacing) {
                    if columns.hash {
                        hash.frame(width: widths.hash, alignment: .leading)
                    }
                    summary
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if columns.author {
                        author.frame(width: widths.author, alignment: .leading)
                    }
                    if columns.date {
                        date.frame(width: widths.date, alignment: .leading)
                    }
                }
                .font(size == .compact ? .callout : nil)
                .padding(.vertical, size == .compact ? 2 : 5)
            }
        }
        .padding(.leading, showsGraph ? GraphCell.width(forLanes: graphWidth) + 6 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            if showsGraph {
                GraphCell(row: row.graph, width: graphWidth, fold: row.fold, toggleFold: toggleFold)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isHead ? "HEAD" : "")
    }

    private var summary: some View {
        HStack(spacing: 4) {
            ForEach(labels) { label in
                RefBadge(label: label)
                    .fixedSize()
            }
            Text(row.commit.summary)
                .fontWeight(isHead ? .bold : nil)
                .lineLimit(1)
            if hasNote {
                NoteMark()
            }
        }
    }

    private var author: some View {
        Text(row.commit.author.name)
            .lineLimit(1)
    }

    private var hash: some View {
        Text(row.commit.id.abbreviated())
            .font(.smallCode)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var date: some View {
        // The row's own text, with figures of one width so dates line up.
        Text(row.commit.author.date, format: .dateTime.day().month(.defaultDigits).year(.twoDigits))
            .monospacedDigit()
            .lineLimit(1)
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
        SheetStack("New Branch") {
            Form {
                SheetTitleSection()
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                LabeledContent("Starting Point") {
                    Text(startingPoint?.abbreviated() ?? "HEAD")
                        .font(.code)
                }
                Toggle("Check Out", isOn: $checksOut)
            }
            .groupedFormStyle()
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
            await model.perform(checksOut ? .checkout : .createBranch) { repository in
                let branch = try await repository.createBranch(named: name, at: startingPoint)
                if checksOut {
                    try await repository.checkOut(branch: branch)
                }
            }
        }
    }
}
