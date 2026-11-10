import Foundation
#if os(macOS)
import CoreServices
#endif

/// A path the file system reported as changed.
struct FileSystemEvent: Sendable {
    var path: String
    /// Set when the file system could not say exactly what changed below a
    /// folder, so everything has to be read again.
    var isRescan = false
    /// Orders events against `RepositoryWatcher.currentStamp()`: an event
    /// stamped before a refresh began was read by that refresh.
    var stamp: UInt64
}

/// Reports changes to a repository's folders as they happen.
///
/// This is the one place where the platforms watch differently. macOS has
/// FSEvents, which watches a whole tree recursively, works on a
/// security-scoped folder while the app holds access to it, and can leave
/// out the app's own writes. iOS has no recursive watcher, so it watches the
/// folders where git's state lives (the git directory and its `refs`) and
/// the top of the working tree, and the window also refreshes when the app
/// becomes active.
enum RepositoryWatcher {
    /// Batches of changes under `locations.roots`, until the stream is no
    /// longer iterated.
    static func events(in locations: RepositoryLocations) -> AsyncStream<[FileSystemEvent]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let source = Source(locations: locations, continuation: continuation)
            continuation.onTermination = { _ in source.stop() }
            source.start()
        }
    }

    /// A stamp later than every event already reported.
    static func currentStamp() -> UInt64 {
        #if os(macOS)
        FSEventsGetCurrentEventId()
        #else
        DispatchTime.now().uptimeNanoseconds
        #endif
    }
}

#if os(macOS)

extension RepositoryWatcher {
    private final class Source: @unchecked Sendable {
        // Touched only on `queue`, apart from `start` before any event arrives.
        private let locations: RepositoryLocations
        private let continuation: AsyncStream<[FileSystemEvent]>.Continuation
        private let queue = DispatchQueue(label: "Twig.RepositoryWatcher")
        private var stream: FSEventStreamRef?

        init(locations: RepositoryLocations, continuation: AsyncStream<[FileSystemEvent]>.Continuation) {
            self.locations = locations
            self.continuation = continuation
        }

        func start() {
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    // Twig's own writes are followed by its own refresh.
                    | kFSEventStreamCreateFlagIgnoreSelf
                    | kFSEventStreamCreateFlagWatchRoot
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
                guard let info else { return }
                let source = Unmanaged<Source>.fromOpaque(info).takeUnretainedValue()
                let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                let rescan = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                )
                let events = (0..<count).map { index in
                    FileSystemEvent(
                        path: String(cString: paths[index]), isRescan: flags[index] & rescan != 0, stamp: ids[index]
                    )
                }
                source.continuation.yield(events)
            }
            queue.sync {
                guard let stream = FSEventStreamCreate(
                    nil, callback, &context, locations.roots as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags
                ) else {
                    continuation.finish()
                    return
                }
                self.stream = stream
                FSEventStreamSetDispatchQueue(stream, queue)
                FSEventStreamStart(stream)
            }
        }

        func stop() {
            // On the queue, so no callback is running while the stream goes.
            queue.async { [self] in
                guard let stream else { return }
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }
}

#else

extension RepositoryWatcher {
    /// Watches folders with vnode sources. A folder's source fires when an
    /// entry in it is added, removed or renamed, which is how git writes
    /// `HEAD`, the index and refs; the folder is then listed again and the
    /// entries that differ are reported by name.
    private final class Source: @unchecked Sendable {
        /// File descriptors are few on iOS; libgit2 needs its own.
        private static let folderLimit = 48

        // Touched only on `queue`.
        private let locations: RepositoryLocations
        private let continuation: AsyncStream<[FileSystemEvent]>.Continuation
        private let queue = DispatchQueue(label: "Twig.RepositoryWatcher")
        private var sources: [String: DispatchSourceFileSystemObject] = [:]
        private var listings: [String: [String: Entry]] = [:]
        private var isStopped = false

        private struct Entry: Equatable {
            var isDirectory: Bool
            var modified: timespec
            var size: off_t
            var inode: ino_t

            static func == (lhs: Entry, rhs: Entry) -> Bool {
                lhs.isDirectory == rhs.isDirectory && lhs.size == rhs.size && lhs.inode == rhs.inode
                    && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
            }
        }

        init(locations: RepositoryLocations, continuation: AsyncStream<[FileSystemEvent]>.Continuation) {
            self.locations = locations
            self.continuation = continuation
        }

        func start() {
            queue.async { [self] in
                for folder in Set([locations.gitDirectory, locations.commonDirectory]) {
                    watch(folder)
                    watchTree(folder + "/refs")
                }
                if let workTree = locations.workTree {
                    watch(workTree)
                    // One level down too: most edits are a folder or two deep,
                    // and a deeper tree would use up the descriptors.
                    for (name, entry) in listings[workTree] ?? [:] where entry.isDirectory && name != ".git" {
                        watch(workTree + "/" + name)
                    }
                }
            }
        }

        func stop() {
            queue.async { [self] in
                isStopped = true
                sources.values.forEach { $0.cancel() }
                sources = [:]
            }
        }

        private func watchTree(_ folder: String) {
            watch(folder)
            for (name, entry) in listings[folder] ?? [:] where entry.isDirectory {
                watchTree(folder + "/" + name)
            }
        }

        private func watch(_ folder: String) {
            guard !isStopped, sources[folder] == nil, sources.count < Self.folderLimit else { return }
            let descriptor = open(folder, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .link], queue: queue
            )
            source.setEventHandler { [weak self] in self?.folderChanged(folder) }
            source.setCancelHandler { close(descriptor) }
            sources[folder] = source
            listings[folder] = list(folder)
            source.resume()
        }

        private func folderChanged(_ folder: String) {
            let stamp = RepositoryWatcher.currentStamp()
            guard let source = sources[folder] else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // The folder itself went or moved: stop watching it, and let
                // a full refresh find out what is there now.
                source.cancel()
                sources[folder] = nil
                listings[folder] = nil
                continuation.yield([FileSystemEvent(path: folder, isRescan: true, stamp: stamp)])
                return
            }
            let old = listings[folder] ?? [:]
            let new = list(folder)
            listings[folder] = new
            var changed = Set(old.keys).symmetricDifference(new.keys)
            for (name, entry) in new where old[name] != nil && old[name] != entry {
                changed.insert(name)
            }
            guard !changed.isEmpty else { return }
            let isRefsFolder = [locations.gitDirectory, locations.commonDirectory].contains { folder.isInside($0 + "/refs") }
            for name in changed where new[name]?.isDirectory == true && isRefsFolder {
                // A branch name with a slash makes a new folder of refs.
                watchTree(folder + "/" + name)
            }
            continuation.yield(changed.map { FileSystemEvent(path: folder + "/" + $0, stamp: stamp) })
        }

        private func list(_ folder: String) -> [String: Entry] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [:] }
            var entries: [String: Entry] = [:]
            for name in names {
                var information = stat()
                guard lstat(folder + "/" + name, &information) == 0 else { continue }
                entries[name] = Entry(
                    isDirectory: information.st_mode & S_IFMT == S_IFDIR, modified: information.st_mtimespec,
                    size: information.st_size, inode: information.st_ino
                )
            }
            return entries
        }
    }
}

#endif
