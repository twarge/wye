import FileProvider
import WyeShared

/// Lists a folder of the location from disk, a page at a time, and reports
/// what changed in it since the last listing.
///
/// A sync anchor may hold only 500 bytes, too few for a folder's listing,
/// so the listing an anchor stands for is kept in memory, under an anchor
/// naming this run of the extension. An anchor from an earlier run is
/// reported as expired, and the system then lists the folder afresh.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let path: FilesPath
    private let storage: URL

    init(path: FilesPath, storage: URL) {
        self.path = path
        self.storage = storage
        super.init()
        FilesObservedFolders.note(path)
    }

    func invalidate() {
        FilesObservedFolders.forget(path)
    }

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let items = currentItems()
        // A page is the offset to start at; the system's first pages are not.
        let start = Int(String(decoding: page.rawValue, as: UTF8.self)) ?? 0
        let size = max(observer.suggestedPageSize ?? 200, 50)
        let end = min(start + size, items.count)
        if start < end {
            observer.didEnumerate(Array(items[start..<end]))
        }
        if start == 0 {
            Listings.shared.record(items, for: path)
        }
        let next = end < items.count ? NSFileProviderPage(Data(String(end).utf8)) : nil
        observer.finishEnumerating(upTo: next)
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard let previous = Listings.shared.listing(for: path, at: anchor) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        let items = currentItems()
        let now = Dictionary(items.map { ($0.itemIdentifier, $0.version) }, uniquingKeysWith: { first, _ in first })
        let deleted = previous.keys.filter { now[$0] == nil }
        let updated = items.filter { previous[$0.itemIdentifier] != $0.version }
        if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: Array(deleted)) }
        if !updated.isEmpty { observer.didUpdate(updated) }
        observer.finishEnumeratingChanges(upTo: Listings.shared.record(items, for: path), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Listings.shared.anchor(for: path))
    }

    /// The folder's items, sorted by name; for a file, the file itself.
    private func currentItems() -> [FileProviderItem] {
        guard let item = FileProviderItem(path: path, storage: storage) else { return [] }
        guard item.isDirectory || path.isRoot else { return [item] }
        return FileProviderItem.listedChildren(of: path, storage: storage)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { name in path.appending(name).flatMap { FileProviderItem(path: $0, storage: storage) } }
    }
}

/// An enumerator for the working set (Recents and tags), which the location
/// keeps empty: the working trees are folders to open, not documents.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    private static let anchor = NSFileProviderSyncAnchor(Data("empty".utf8))

    func invalidate() {}

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor)
    }
}

/// The last listing of each folder enumerated in this run, by anchor.
private final class Listings: @unchecked Sendable {
    static let shared = Listings()

    /// Names this run of the extension in every anchor it gives out.
    private let run = UUID().uuidString
    private let lock = NSLock()
    // Guarded by `lock`.
    private var listings: [FilesPath: (generation: Int, versions: [NSFileProviderItemIdentifier: Data])] = [:]
    private var generation = 0

    /// Keeps a folder's listing, and returns the anchor that stands for it.
    @discardableResult
    func record(_ items: [FileProviderItem], for path: FilesPath) -> NSFileProviderSyncAnchor {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        let versions = Dictionary(items.map { ($0.itemIdentifier, $0.version) }, uniquingKeysWith: { first, _ in first })
        listings[path] = (generation, versions)
        return makeAnchor(generation)
    }

    /// The listing an anchor stands for, if it is this run's latest.
    func listing(for path: FilesPath, at anchor: NSFileProviderSyncAnchor) -> [NSFileProviderItemIdentifier: Data]? {
        lock.lock()
        defer { lock.unlock() }
        guard let listing = listings[path], anchor == makeAnchor(listing.generation) else { return nil }
        return listing.versions
    }

    func anchor(for path: FilesPath) -> NSFileProviderSyncAnchor {
        lock.lock()
        defer { lock.unlock() }
        // A folder not listed yet in this run: an anchor no listing has,
        // so changes from it are answered with a fresh listing.
        return makeAnchor(listings[path]?.generation ?? 0)
    }

    private func makeAnchor(_ generation: Int) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(run):\(generation)".utf8))
    }
}
