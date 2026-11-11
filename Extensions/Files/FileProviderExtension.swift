import FileProvider
import UniformTypeIdentifiers
import WyeShared

/// Wye's location in the Files app: the repositories in the provider's
/// document storage, which the app clones and creates into, each shown as
/// a folder that other apps can open and edit in place.
///
/// This is the non-replicated model: an item's URL is the real file in the
/// working tree, which the app's libgit2 reads and writes directly, so
/// nothing is copied or synchronised. Items are named by their path below
/// the storage (`FilesPath`), and git's own data is never listed, opened,
/// changed or moved through here.
final class FileProviderExtension: NSFileProviderExtension {
    private let storage: URL = NSFileProviderManager.default.documentStorageURL

    // MARK: Items and their files

    override func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        guard let path = FilesPath(identifier), let item = FileProviderItem(path: path, storage: storage) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return item
    }

    override func urlForItem(withPersistentIdentifier identifier: NSFileProviderItemIdentifier) -> URL? {
        FilesPath(identifier)?.url(in: storage)
    }

    override func persistentIdentifierForItem(at url: URL) -> NSFileProviderItemIdentifier? {
        FilesPath(url: url, in: storage).map(NSFileProviderItemIdentifier.init)
    }

    override func providePlaceholder(at url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        // Every item is already on disk where its URL says, so a placeholder
        // is never needed; writing one would leave a stray file in the
        // working tree for git to see.
        completionHandler(FilesPath(url: url, in: storage) == nil ? NSFileProviderError(.noSuchItem) : nil)
    }

    override func startProvidingItem(at url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        let exists = FilesPath(url: url, in: storage) != nil
            && FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        completionHandler(exists ? nil : NSFileProviderError(.noSuchItem))
    }

    override func stopProvidingItem(at url: URL) {
        // The file is the working tree's own: it stays.
    }

    override func itemChanged(at url: URL) {
        // Another app saved the file in place.
        guard let path = FilesPath(url: url, in: storage) else { return }
        changed([path.parent ?? .root])
    }

    // MARK: Listing

    override func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet {
            return EmptyEnumerator()
        }
        guard let path = FilesPath(containerItemIdentifier), FileProviderItem(path: path, storage: storage) != nil else {
            throw NSFileProviderError(.noSuchItem)
        }
        return FileProviderEnumerator(path: path, storage: storage)
    }

    // MARK: Changes made in the Files app and in document pickers

    override func importDocument(
        at fileURL: URL, toParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
    ) {
        do {
            let parent = try writableFolder(parentItemIdentifier)
            let isScoped = fileURL.startAccessingSecurityScopedResource()
            defer {
                if isScoped { fileURL.stopAccessingSecurityScopedResource() }
            }
            let target = try freePath(for: fileURL.lastPathComponent, in: parent)
            var coordinationError: NSError?
            var copyError: (any Error)?
            NSFileCoordinator().coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinationError) { source in
                do {
                    try FileManager.default.copyItem(at: source, to: target.url(in: storage))
                } catch {
                    copyError = error
                }
            }
            if let error = coordinationError ?? copyError { throw error }
            completionHandler(try finished(target, changing: [parent]), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    override func createDirectory(
        withName directoryName: String, inParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
    ) {
        do {
            let parent = try writableFolder(parentItemIdentifier)
            guard let target = parent.appending(directoryName) else { throw Self.refused }
            guard !exists(target) else { throw NSFileProviderError(.filenameCollision) }
            try FileManager.default.createDirectory(at: target.url(in: storage), withIntermediateDirectories: false)
            completionHandler(try finished(target, changing: [parent]), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    override func renameItem(
        withIdentifier itemIdentifier: NSFileProviderItemIdentifier, toName itemName: String,
        completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
    ) {
        do {
            guard let source = FilesPath(itemIdentifier), exists(source) else { throw NSFileProviderError(.noSuchItem) }
            guard let parent = source.parent else { throw Self.refused }
            completionHandler(try move(source, into: parent, as: itemName), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    override func reparentItem(
        withIdentifier itemIdentifier: NSFileProviderItemIdentifier,
        toParentItemWithIdentifier parentItemIdentifier: NSFileProviderItemIdentifier, newName: String?,
        completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
    ) {
        do {
            guard let source = FilesPath(itemIdentifier), exists(source) else { throw NSFileProviderError(.noSuchItem) }
            guard let parent = FilesPath(parentItemIdentifier), isFolder(parent) else {
                throw NSFileProviderError(.noSuchItem)
            }
            completionHandler(try move(source, into: parent, as: newName ?? source.name), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    override func deleteItem(
        withIdentifier itemIdentifier: NSFileProviderItemIdentifier, completionHandler: @escaping ((any Error)?) -> Void
    ) {
        do {
            guard let path = FilesPath(itemIdentifier), exists(path) else { throw NSFileProviderError(.noSuchItem) }
            // A repository's own folder is removed in Wye, which knows what
            // else goes with it.
            guard FilesPermissions.of(path).contains(.delete), let parent = path.parent else { throw Self.refused }
            try FileManager.default.removeItem(at: path.url(in: storage))
            changed([parent])
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    // MARK: Helpers

    /// What an action the location does not allow answers with.
    private static var refused: any Error { CocoaError(.fileWriteNoPermission) }

    private func move(_ source: FilesPath, into parent: FilesPath, as name: String) throws -> NSFileProviderItem {
        guard FilesPermissions.canMove(source, into: parent, as: name), isFolder(parent),
              let target = parent.appending(name) else { throw Self.refused }
        if target == source { return try finished(target, changing: []) }
        // A change of case only is a rename onto itself on a file system
        // that ignores case, which `exists` would call a collision.
        let caseOnly = target.parent == source.parent && target.name.lowercased() == source.name.lowercased()
        guard caseOnly || !exists(target) else { throw NSFileProviderError(.filenameCollision) }
        try FileManager.default.moveItem(at: source.url(in: storage), to: target.url(in: storage))
        return try finished(target, changing: [source.parent ?? .root, parent])
    }

    /// The folder at `identifier`, when new items may go into it.
    private func writableFolder(_ identifier: NSFileProviderItemIdentifier) throws -> FilesPath {
        guard let parent = FilesPath(identifier), isFolder(parent) else { throw NSFileProviderError(.noSuchItem) }
        guard FilesPermissions.of(parent).contains(.write) else { throw Self.refused }
        return parent
    }

    /// `name` in `parent`, or the first of "name 2", "name 3"… not taken,
    /// as the Files app names a copy.
    private func freePath(for name: String, in parent: FilesPath) throws -> FilesPath {
        guard let first = parent.appending(name) else { throw Self.refused }
        guard exists(first) else { return first }
        let base = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        for number in 2...999 {
            let candidate = suffix.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(suffix)"
            if let path = parent.appending(candidate), !exists(path) { return path }
        }
        throw NSFileProviderError(.filenameCollision)
    }

    private func exists(_ path: FilesPath) -> Bool {
        // Not following a link at the end of the path.
        (try? FileManager.default.attributesOfItem(atPath: path.url(in: storage).path(percentEncoded: false))) != nil
    }

    private func isFolder(_ path: FilesPath) -> Bool {
        FileProviderItem(path: path, storage: storage)?.isDirectory ?? path.isRoot
    }

    /// The item now at `path`, after telling the app and the folders'
    /// listings about the change.
    private func finished(_ path: FilesPath, changing folders: [FilesPath]) throws -> NSFileProviderItem {
        changed(folders)
        guard let item = FileProviderItem(path: path, storage: storage) else { throw NSFileProviderError(.noSuchItem) }
        return item
    }

    /// Tells the app, which refreshes an open repository, and asks the
    /// system to list the folders again.
    private func changed(_ folders: [FilesPath]) {
        FilesLocation.postChange()
        for folder in Set(folders) {
            NSFileProviderManager.default.signalEnumerator(for: NSFileProviderItemIdentifier(folder)) { _ in }
        }
    }
}
