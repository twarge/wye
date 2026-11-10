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

    private let repository: Repository
    private let pageSize = 300
    private var cursor: HistoryCursor?
    private var graph = CommitGraph()
    private var lastPeriod: DateComponents?
    private var isLoadingMore = false
    /// Counts reloads, so a page read for an earlier one is dropped, and a
    /// search knows to run again.
    private(set) var generation = 0

    init(repository: Repository) {
        self.repository = repository
        search = SearchModel(repository: repository)
        reflog = ReflogModel(repository: repository)
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

    /// Lays the history out again for changed view options.
    func apply(_ layout: HistoryLayout) async {
        guard layout != self.layout else { return }
        self.layout = layout
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
        do {
            let cursor = try await repository.openHistory(scope, options: layout.options)
            guard generation == self.generation else {
                await repository.closeHistory(cursor)
                return
            }
            self.cursor = cursor
            page = try await repository.nextCommits(from: cursor, limit: pageSize)
        } catch {
            // A branch with no commits, or a reference that has gone.
            page = []
        }
        guard generation == self.generation else { return }

        items = []
        graph = CommitGraph()
        lastPeriod = nil
        graphWidth = 1
        append(page)
        if let selection, !contains(selection) {
            self.selection = nil
        }
        multipleSelection = multipleSelection.filter(contains)
        if multipleSelection.count < 2 { multipleSelection = [] }

        let count = try? await repository.commitCount(in: scope, options: layout.options)
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
        guard let page = try? await repository.nextCommits(from: cursor, limit: pageSize),
              generation == self.generation else { return }
        append(page)
    }

    /// Selects a commit and scrolls to it, reading on until it is reached.
    /// Returns `false` when the history does not hold it.
    @discardableResult
    func reveal(_ id: OID, readingAtMost limit: Int = 50_000) async -> Bool {
        await search.cancelAndClear()
        while !contains(id), !isComplete, rowCount < limit {
            let count = items.count
            await loadMore()
            if items.count == count { break }
        }
        guard contains(id) else { return false }
        selection = id
        scrollTarget = id
        return true
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

    private func contains(_ id: OID) -> Bool {
        items.contains { $0.id == .commit(id) }
    }

    private func append(_ commits: [Commit]) {
        isComplete = commits.count < pageSize
        let calendar = Calendar.current
        let components: Set<Calendar.Component>? = switch layout.grouping {
        case .day: [.year, .month, .day]
        case .week: [.yearForWeekOfYear, .weekOfYear]
        case .month: [.year, .month]
        case .none: nil
        }
        let firstParentOnly = layout.options.firstParentOnly
        for commit in commits {
            if let components {
                let period = calendar.dateComponents(components, from: commit.author.date)
                if period != lastPeriod {
                    lastPeriod = period
                    items.append(.heading(commit.author.date, layout.grouping, before: commit.id, lines: graph.openLines))
                }
            }
            // Following first parents only, the other parents are not listed
            // and get no lane.
            let parents = firstParentOnly ? Array(commit.parentIDs.prefix(1)) : commit.parentIDs
            let row = graph.append(commit.id, parents: parents)
            graphWidth = max(graphWidth, row.width)
            items.append(.commit(Row(commit: commit, graph: row)))
        }
    }
}
