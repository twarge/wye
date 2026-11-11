import Foundation
import GitKit
import Observation

/// A search of the history being shown: the field's text, and the commits
/// found so far, read a page at a time like the history itself.
@MainActor
@Observable
final class SearchModel {
    var text = ""
    var field: HistoryQuery.Field = .message
    /// Dates, authors and branches, shown as tokens in the search field.
    var filters = HistoryFilters()

    /// The matches so far, in the history's order.
    private(set) var results: [Commit] = []
    /// How many commits have been looked at.
    private(set) var examined = 0
    /// Whether the whole history has been searched.
    private(set) var isComplete = true

    var query: HistoryQuery { HistoryQuery(field, text) }
    /// Whether the list shows results rather than the history: there is
    /// text to search for, or a filter that picks commits one by one.
    /// Branch filters alone change the history itself, graph and all.
    var isActive: Bool { !query.isEmpty || !filters.commitFilter.isEmpty }
    /// Whether there is anything to clear: text or any filter.
    var hasAnything: Bool { !query.isEmpty || !filters.isEmpty }

    private let repository: Repository
    private let pageSize = 100
    private var cursor: HistoryCursor?
    private var running: HistoryQuery?
    private var runningFilter = HistoryFilter()
    private var isLoadingMore = false
    /// Counts searches, so a page read for an earlier one is dropped.
    private var generation = 0

    init(repository: Repository) {
        self.repository = repository
    }

    /// Starts searching `scope` for `query`, dropping any earlier search.
    /// Stops after the first page of matches; `loadMore` reads on.
    func search(
        _ query: HistoryQuery, filter: HistoryFilter = HistoryFilter(), in scope: HistoryScope,
        options: HistoryOptions = HistoryOptions()
    ) async {
        generation += 1
        let generation = generation
        await closeCursor()
        results = []
        examined = 0
        isComplete = true
        running = query
        runningFilter = filter
        guard !query.isEmpty || !filter.isEmpty else { return }
        isComplete = false
        do {
            let cursor = try await repository.openHistory(scope, options: options)
            guard generation == self.generation else {
                await repository.closeHistory(cursor)
                return
            }
            self.cursor = cursor
        } catch {
            // A branch with no commits, or a reference that has gone.
            isComplete = true
            return
        }
        await read(until: pageSize, generation: generation)
    }

    /// Reads on, when the list has scrolled to its end.
    func loadMore() async {
        guard !isComplete, !isLoadingMore else { return }
        await read(until: results.count + pageSize, generation: generation)
    }

    /// Abandons the search and empties the field, filters and all, so the
    /// list shows the whole history again.
    func cancelAndClear() async {
        text = ""
        filters = HistoryFilters()
        results = []
        examined = 0
        await cancel()
    }

    /// Abandons the search, leaving the text as it is.
    func cancel() async {
        generation += 1
        await closeCursor()
        isComplete = true
    }

    /// Reads pages until there are `wanted` matches or the history ends. Each
    /// page examines a bounded number of commits, so a rare match in a large
    /// repository still returns to the main actor between pages, where a
    /// newer search or a cancelled task stops it.
    private func read(until wanted: Int, generation: Int) async {
        guard let cursor, let query = running else { return }
        isLoadingMore = true
        defer { if generation == self.generation { isLoadingMore = false } }
        while results.count < wanted, !isComplete {
            guard !Task.isCancelled else { return }
            let page: SearchPage
            do {
                page = try await repository.nextMatches(
                    from: cursor, matching: query, filter: runningFilter, limit: wanted - results.count
                )
            } catch {
                isComplete = true
                break
            }
            guard generation == self.generation else { return }
            results += page.matches
            examined += page.examined
            isComplete = page.isComplete
        }
        if isComplete {
            await closeCursor()
        }
    }

    private func closeCursor() async {
        if let cursor {
            self.cursor = nil
            await repository.closeHistory(cursor)
        }
    }
}

extension HistoryQuery.Field: Identifiable {
    public var id: Self { self }

    var title: String {
        switch self {
        case .message: "Message"
        case .author: "Author"
        case .hash: "Hash"
        case .path: "Path"
        }
    }

    var prompt: String {
        switch self {
        case .message: "Search messages"
        case .author: "Search authors"
        case .hash: "Search hashes"
        case .path: "Search changed paths"
        }
    }
}
