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

    /// A line of the list: a commit, or the heading above a month's commits.
    enum Item: Identifiable {
        /// The heading carries the graph lines that run past it.
        case month(Date, before: OID, lines: [CommitGraph.Line])
        case commit(Row)

        enum ID: Hashable {
            case month(OID)
            case commit(OID)
        }

        var id: ID {
            switch self {
            case .month(_, let before, _): .month(before)
            case .commit(let row): .commit(row.id)
            }
        }
    }

    var selection: OID?
    private(set) var items: [Item] = []
    private(set) var scope: HistoryScope = .allReferences
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
    private var lastMonth: DateComponents?
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
        items = []
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
            let cursor = try await repository.openHistory(scope)
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
        lastMonth = nil
        graphWidth = 1
        append(page)
        if let selection, !items.contains(where: { $0.id == .commit(selection) }) {
            self.selection = nil
        }

        let count = try? await repository.commitCount(in: scope)
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

    private func append(_ commits: [Commit]) {
        isComplete = commits.count < pageSize
        let calendar = Calendar.current
        for commit in commits {
            let month = calendar.dateComponents([.year, .month], from: commit.author.date)
            if month != lastMonth {
                lastMonth = month
                items.append(.month(commit.author.date, before: commit.id, lines: graph.openLines))
            }
            let row = graph.append(commit.id, parents: commit.parentIDs)
            graphWidth = max(graphWidth, row.width)
            items.append(.commit(Row(commit: commit, graph: row)))
        }
    }
}
