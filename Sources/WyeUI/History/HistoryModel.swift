import Foundation
import GitKit
import Observation

/// A history being shown: its commits, read a page at a time, and their graph.
@MainActor
@Observable
final class HistoryModel {
    struct Row: Identifiable {
        let commit: Commit
        let graph: CommitGraph.Row
        /// For a merge whose branch can fold away: whether it is folded.
        var fold: GraphCell.Fold?

        var id: OID { commit.id }
    }

    /// A line of the list: a commit, or the heading above a day's, week's or
    /// month's commits.
    enum Item: Identifiable {
        /// The heading carries the graph lines that run past it.
        case heading(Date, HistoryPreferences.Grouping, before: OID, lines: [CommitGraph.Line])
        case commit(Row)

        enum ID: Hashable {
            case heading(OID)
            case commit(OID)
        }

        var id: ID {
            switch self {
            case .heading(_, _, let before, _): .heading(before)
            case .commit(let row): .commit(row.id)
            }
        }
    }

    /// The commit the detail column shows. Setting it to one outside the
    /// multiple selection ends that selection.
    var selection: OID? {
        didSet {
            if let selection, !multipleSelection.contains(selection) {
                multipleSelection = []
            }
        }
    }

    /// The commits selected together, when there are two or more. The one
    /// `selection` names stays in detail while it is among them.
    private(set) var multipleSelection: Set<OID> = []

    /// The list's selection: one commit, or several.
    var listSelection: Set<OID> {
        get {
            if multipleSelection.count > 1 { return multipleSelection }
            return selection.map { [$0] } ?? []
        }
        set {
            guard newValue.count > 1 else {
                multipleSelection = []
                selection = newValue.first
                return
            }
            if selection.map({ !newValue.contains($0) }) ?? true {
                selection = newValue.subtracting(multipleSelection).first ?? newValue.first
            }
            multipleSelection = newValue
        }
    }

    /// Sheets and files the commit menus ask for.
    let requests = CommitActionRequests()
    /// The commit the list scrolls to next.
    private(set) var scrollTarget: OID?

    private(set) var items: [Item] = []
    private(set) var scope: HistoryScope = .allReferences
    private(set) var layout = HistoryPreferences.shared.layout
    /// How the engine reads this history: the layout's options with the
    /// branch filters applied.
    private(set) var options = HistoryPreferences.shared.layout.options
    /// How many commits the whole history holds, once counted.
    private(set) var commitCount: Int?
    /// Whether every commit has been read.
    private(set) var isComplete = false
    /// The widest the graph gets among the rows read so far, in lanes.
    private(set) var graphWidth = 1
    /// A search of this history, which the list shows instead while active.
    let search: SearchModel
    /// The reflog the sidebar's Reflog item lists.
    let reflog: ReflogModel
    /// Commit notes: which commits have one, and the note being edited.
    let notes: CommitNotes

    private let repository: Repository
    private let pageSize = 300
    private var cursor: HistoryCursor?
    private var graph = CommitGraph()
    /// Where the line the graph keeps straight in its first lane starts.
    private var mainLine: OID?
    private var lastPeriod: DateComponents?
    /// Every commit read so far, hidden or not, to lay out again when a
    /// merge folds or unfolds.
    private var commitsRead: [Commit] = []
    /// The merges folded shut, each with the commits it brought in, which
    /// the list leaves out.
    private var folded: [OID: Set<OID>] = [:]
    private var hidden: Set<OID> = []
    private var isLoadingMore = false
    /// Counts reloads, so a page read for an earlier one is dropped, and a
    /// search knows to run again.
    private(set) var generation = 0

    init(repository: Repository) {
        self.repository = repository
        search = SearchModel(repository: repository)
        reflog = ReflogModel(repository: repository)
        notes = CommitNotes(repository: repository)
    }

    /// Switches to another history.
    func show(_ scope: HistoryScope) async {
        guard scope != self.scope else { return }
        self.scope = scope
        selection = nil
        multipleSelection = []
        items = []
        await reload()
    }

    /// Lays the history out again for changed view options or branch filters.
    func apply(_ layout: HistoryLayout, filters: HistoryFilters = HistoryFilters()) async {
        let options = filters.applied(to: layout.options)
        guard layout != self.layout || options != self.options else { return }
        self.layout = layout
        self.options = options
        await reload()
    }

    /// Reads the history again from the top.
    func reload() async {
        generation += 1
        let generation = generation
        if let cursor {
            await repository.closeHistory(cursor)
            self.cursor = nil
        }

        // The list keeps showing what it has until the first page arrives.
        let page: [Commit]
        var mainLine: OID?
        do {
            let cursor = try await repository.openHistory(scope, options: options)
            guard generation == self.generation else {
                await repository.closeHistory(cursor)
                return
            }
            self.cursor = cursor
            page = try await repository.nextCommits(from: cursor, limit: pageSize)
            mainLine = try? await repository.mainLine(of: scope, options: options)
        } catch {
            // A branch with no commits, or a reference that has gone.
            page = []
        }
        guard generation == self.generation else { return }

        commitsRead = []
        self.mainLine = mainLine
        resetLayout()
        append(page)
        if let selection, !contains(selection) {
            self.selection = nil
        }
        multipleSelection = multipleSelection.filter(contains)
        if multipleSelection.count < 2 { multipleSelection = [] }

        await notes.reload()
        let count = try? await repository.commitCount(in: scope, options: options)
        if generation == self.generation {
            commitCount = count ?? 0
        }
    }

    /// Reads the next page, when the list has scrolled to its end.
    func loadMore() async {
        guard let cursor, !isComplete, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = generation
        // A page may be all commits of folded merges: read on until rows arrive.
        let count = items.count
        while items.count == count, !isComplete {
            guard let page = try? await repository.nextCommits(from: cursor, limit: pageSize),
                  generation == self.generation else { return }
            append(page)
        }
    }

    /// Folds a merge shut, hiding the commits it brought in, or opens it.
    func toggleFold(of merge: OID) async {
        if folded[merge] != nil {
            folded[merge] = nil
        } else {
            guard let merged = try? await repository.commitsMerged(by: merge), !merged.isEmpty else { return }
            folded[merge] = Set(merged)
        }
        layOutAgain()
        // A selected commit that folded away gives its place to the merge.
        if let selection, hidden.contains(selection) {
            self.selection = merge
        }
        multipleSelection.subtract(hidden)
        if multipleSelection.count < 2 { multipleSelection = [] }
    }

    private func layOutAgain() {
        hidden = folded.values.reduce(into: []) { $0.formUnion($1) }
        resetLayout()
        layOut(commitsRead)
    }

    private func resetLayout() {
        items = []
        // None where a folded merge hides where it starts.
        graph = CommitGraph(mainLine: mainLine.flatMap { hidden.contains($0) ? nil : $0 })
        lastPeriod = nil
        graphWidth = 1
    }

    /// Selects a commit and scrolls to it, reading on until it is reached.
    /// Returns `false` when the history does not hold it.
    @discardableResult
    func reveal(_ id: OID, readingAtMost limit: Int = 50_000) async -> Bool {
        await search.cancelAndClear()
        // Without the branch filters, which may have hidden it.
        await apply(layout)
        // Out of any folded merge too.
        let holding = folded.filter { $0.value.contains(id) }.keys
        if !holding.isEmpty {
            for merge in holding { folded[merge] = nil }
            layOutAgain()
        }
        // Until another reveal takes its place.
        while !contains(id), !isComplete, rowCount < limit, !Task.isCancelled {
            let count = items.count
            await loadMore()
            if items.count == count { break }
        }
        guard contains(id), !Task.isCancelled else { return false }
        selection = id
        scrollTarget = id
        return true
    }

    /// Selects a commit and scrolls to it: where the list shows it already,
    /// leaving the search and branch filters as they are; otherwise as
    /// `reveal(_:)` does.
    @discardableResult
    func select(_ id: OID) async -> Bool {
        if !search.isActive, contains(id) {
            selection = id
            scrollTarget = id
            return true
        }
        return await reveal(id)
    }

    func didScroll() {
        scrollTarget = nil
    }

    /// The commits among `ids`, in the order the list shows them: newest
    /// first, as the history lists them.
    func commits(_ ids: Set<OID>) -> [Commit] {
        if search.isActive {
            return search.results.filter { ids.contains($0.id) }
        }
        return items.compactMap { item in
            if case .commit(let row) = item, ids.contains(row.id) { return row.commit }
            return nil
        }
    }

    private var rowCount: Int { items.count }

    /// The commits read so far, for the author filter's menu.
    var loadedCommits: some Sequence<Commit> {
        items.lazy.compactMap { item in
            if case .commit(let row) = item { return row.commit }
            return nil
        }
    }

    private func contains(_ id: OID) -> Bool {
        items.contains { $0.id == .commit(id) }
    }

    private func append(_ commits: [Commit]) {
        isComplete = commits.count < pageSize
        commitsRead += commits
        layOut(commits)
    }

    private func layOut(_ commits: [Commit]) {
        let calendar = Calendar.current
        let components: Set<Calendar.Component>? = switch layout.grouping {
        case .day: [.year, .month, .day]
        case .week: [.yearForWeekOfYear, .weekOfYear]
        case .month: [.year, .month]
        case .none: nil
        }
        let firstParentOnly = options.firstParentOnly
        for commit in commits where !hidden.contains(commit.id) {
            if let components {
                let period = calendar.dateComponents(components, from: commit.author.date)
                if period != lastPeriod {
                    lastPeriod = period
                    items.append(.heading(commit.author.date, layout.grouping, before: commit.id, lines: graph.openLines))
                }
            }
            // Following first parents only, the other parents are not listed
            // and get no lane.
            // A folded merge draws only the line it sits on, and no line
            // leads to a commit that is folded away.
            let isFolded = folded[commit.id] != nil
            var parents = firstParentOnly || isFolded ? Array(commit.parentIDs.prefix(1)) : commit.parentIDs
            parents.removeAll(where: hidden.contains)
            let row = graph.append(commit.id, parents: parents)
            graphWidth = max(graphWidth, row.width)
            let canFold = commit.parentIDs.count > 1 && !firstParentOnly
            let fold: GraphCell.Fold? = canFold ? (isFolded ? .folded : .open) : nil
            items.append(.commit(Row(commit: commit, graph: row, fold: fold)))
        }
    }
}
