import Foundation
import GitKit
import Observation

/// The commits that changed one file, read a page at a time, and the
/// selected commit's diff of that file.
@MainActor
@Observable
final class FileHistoryModel {
    let path: String
    let startID: OID

    private(set) var entries: [FileHistoryEntry] = []
    private(set) var isComplete = false
    var selection: OID?
    private(set) var diff: FileDiff?

    private let repository: Repository
    private let pageSize = 50
    private var cursor: HistoryCursor?
    /// The file's name further back, which changes at a rename.
    private var followedPath: String
    private var isLoading = false

    init(repository: Repository, path: String, startID: OID) {
        self.repository = repository
        self.path = path
        self.startID = startID
        followedPath = path
    }

    var selectedEntry: FileHistoryEntry? {
        selection.flatMap { id in entries.first { $0.id == id } }
    }

    /// Opens the history, or opens it again from the top when it was closed
    /// before it was read to its end.
    func start() async throws {
        guard cursor == nil, !isComplete else { return }
        entries = []
        followedPath = path
        cursor = try await repository.openHistory(from: startID)
        try await loadMore()
        if selection == nil {
            selection = entries.first?.id
        }
    }

    /// Reads the next page, when the list has scrolled to its end. Pages stop
    /// after a bounded number of commits, so this keeps going until it has
    /// some entries or the history ends.
    func loadMore() async throws {
        guard let cursor, !isComplete, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let wanted = entries.count + pageSize
        while entries.count < wanted, !isComplete, !Task.isCancelled {
            let page = try await repository.nextFileHistory(
                from: cursor, following: followedPath, limit: wanted - entries.count
            )
            entries += page.entries
            followedPath = page.path
            isComplete = page.isComplete
        }
        if isComplete {
            await close()
        }
    }

    func loadDiff() async throws {
        guard let entry = selectedEntry else {
            diff = nil
            return
        }
        let diff = try await repository.fileDiff(in: entry.commit.id, path: entry.path)
        if selection == entry.id {
            self.diff = diff
        }
    }

    func close() async {
        if let cursor {
            self.cursor = nil
            await repository.closeHistory(cursor)
        }
    }
}
