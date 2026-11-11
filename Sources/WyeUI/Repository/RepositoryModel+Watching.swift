import Foundation
import GitKit

/// What the repository watcher needs to know about Wye's own activity, and
/// the changes waiting for a refresh.
@MainActor
final class DiskChanges {
    fileprivate var coalescer = RefreshCoalescer()
    fileprivate var operations = 0
    fileprivate var refreshes = 0
    fileprivate var timer: Task<Void, Never>?
    /// Whether each top-level folder of the working tree is ignored and holds
    /// nothing tracked, as the last check found. Builds write into such
    /// folders constantly, so they are worth remembering.
    fileprivate var ignoredFolders: [String: Bool] = [:]

    /// A refresh is starting: it reads every change made until now.
    func refreshBegan() {
        refreshes += 1
        coalescer.refreshBegan(covering: RepositoryWatcher.currentStamp())
    }

    func refreshEnded() {
        refreshes -= 1
    }

    /// One of Wye's own operations is writing to the repository. Changes it
    /// makes are read by the refresh it ends with.
    func operationBegan() {
        operations += 1
    }

    func operationEnded() {
        operations -= 1
    }

    /// Whether one of Wye's own operations is writing to the repository now.
    var isOperating: Bool {
        operations > 0
    }

    fileprivate func stop() {
        timer?.cancel()
        timer = nil
        coalescer.clear()
    }
}

extension RepositoryModel {
    /// Refreshes when another program changes the repository, for as long as
    /// the calling task runs. The repository window runs this while open.
    func watchForChanges() async {
        let locations = RepositoryLocations(repositoryURL: repository.url, isBare: repository.isBare)
        let filter = RepositoryChangeFilter(locations: locations)
        defer { diskChanges.stop() }
        for await batch in RepositoryWatcher.events(in: locations) {
            await receive(batch, filter: filter)
        }
    }

    /// Whether Wye is reading or writing the repository itself, so a
    /// refresh now would come too early or twice.
    private var isBusyWithOwnWork: Bool {
        diskChanges.operations > 0 || diskChanges.refreshes > 0 || remotes.activity != nil
    }

    private func receive(_ batch: [FileSystemEvent], filter: RepositoryChangeFilter) async {
        var newestStamp: UInt64 = 0
        var workingTree: [(path: String, stamp: UInt64)] = []
        for event in batch {
            switch filter.classify(event.path, isRescan: event.isRescan) {
            case .gitDirectory, .rescan:
                newestStamp = max(newestStamp, event.stamp)
                // The index or the ignore rules may have changed what is tracked or ignored.
                diskChanges.ignoredFolders = [:]
            case .workingTree(let path):
                if path.split(separator: "/").last == ".gitignore" {
                    diskChanges.ignoredFolders = [:]
                }
                workingTree.append((path, event.stamp))
            case nil:
                break
            }
        }
        if !workingTree.isEmpty {
            let mattering = await pathsThatMatter(Set(workingTree.map(\.path)))
            for change in workingTree where mattering.contains(change.path) {
                newestStamp = max(newestStamp, change.stamp)
            }
        }
        guard newestStamp > 0, diskChanges.coalescer.record(stamp: newestStamp, at: .now) else { return }
        scheduleRefreshFromDisk()
    }

    /// The working tree paths whose change can show: not ignored, or tracked
    /// despite the ignore rules.
    private func pathsThatMatter(_ paths: Set<String>) async -> Set<String> {
        func topFolder(of path: String) -> String? {
            let components = path.split(separator: "/", maxSplits: 1)
            return components.count > 1 ? String(components[0]) : nil
        }
        let unknownFolders = Set(paths.compactMap(topFolder)).filter { diskChanges.ignoredFolders[$0] == nil }
        let candidates = paths.filter { topFolder(of: $0).map { diskChanges.ignoredFolders[$0] != true } ?? true }
        // A huge batch is not worth checking file by file: its folders are enough.
        let query = candidates.count + unknownFolders.count > 256 ? unknownFolders : unknownFolders.union(candidates)
        let ignored: Set<String>
        do {
            ignored = try await repository.ignoredUntrackedPaths(among: Array(query))
        } catch {
            return paths
        }
        for folder in unknownFolders {
            diskChanges.ignoredFolders[folder] = ignored.contains(folder)
        }
        return paths.filter { path in
            if let folder = topFolder(of: path), diskChanges.ignoredFolders[folder] == true { return false }
            return !ignored.contains(path)
        }
    }

    /// Refreshes once the pending changes are due, waiting out Wye's own work.
    private func scheduleRefreshFromDisk() {
        guard diskChanges.timer == nil else { return }
        diskChanges.timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let deadline = self.diskChanges.coalescer.deadline else { break }
                let now = ContinuousClock.now
                if self.diskChanges.coalescer.isDue(at: now, isBusy: self.isBusyWithOwnWork) {
                    self.diskChanges.coalescer.clear()
                    await self.refresh()
                } else {
                    // Not due yet, or Wye is busy: look again then. The
                    // refresh that ends Wye's own work usually reads the
                    // changes, which clears them.
                    let wake = deadline > now ? deadline : now + .milliseconds(150)
                    try? await Task.sleep(until: wake, clock: .continuous)
                }
            }
            self?.diskChanges.timer = nil
        }
    }
}
