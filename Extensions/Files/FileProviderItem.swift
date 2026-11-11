import FileProvider
import UniformTypeIdentifiers
import WyeShared

extension NSFileProviderItemIdentifier {
    /// The identifier of the item at `path`: its path, or the system's own
    /// for the top level.
    init(_ path: FilesPath) {
        self = path.identifier.map(NSFileProviderItemIdentifier.init(rawValue:)) ?? .rootContainer
    }
}

extension FilesPath {
    /// The path an identifier names; `nil` for one that is not an item of
    /// the location, such as the working set, or one inside git's data.
    init?(_ identifier: NSFileProviderItemIdentifier) {
        if identifier == .rootContainer {
            self = .root
        } else if identifier == .workingSet || identifier == .trashContainer {
            return nil
        } else {
            self.init(identifier: identifier.rawValue)
        }
    }
}

/// A file or folder in the location, as read from disk when asked for.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let path: FilesPath
    let isDirectory: Bool
    private let isLink: Bool
    private let isWritable: Bool
    private let size: Int?
    private let created: Date?
    private let modified: Date?
    private let type: UTType
    private let children: Int?

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey,
        .contentModificationDateKey, .isWritableKey, .contentTypeKey
    ]

    /// The item at `path` as it is on disk now; `nil` when nothing is there.
    init?(path: FilesPath, storage: URL) {
        let url = path.url(in: storage)
        guard let values = try? url.resourceValues(forKeys: Self.keys) else { return nil }
        self.path = path
        isLink = values.isSymbolicLink ?? false
        isDirectory = !isLink && (values.isDirectory ?? false)
        isWritable = values.isWritable ?? true
        size = isDirectory ? nil : values.fileSize
        created = values.creationDate
        modified = values.contentModificationDate
        // Every folder opens as a folder, even one named like a package.
        type = isLink ? .symbolicLink : isDirectory ? .folder : values.contentType ?? .data
        children = isDirectory ? FileProviderItem.listedChildren(of: path, storage: storage).count : nil
    }

    /// The names of what is listed in a folder, git's own data left out.
    static func listedChildren(of path: FilesPath, storage: URL) -> [String] {
        let folder = path.url(in: storage)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else {
            return []
        }
        return names.filter { name in
            guard path.isRoot else { return FilesLocation.isListed(name, isDirectory: false, in: path) }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: folder.appending(path: name).path(percentEncoded: false), isDirectory: &isDirectory
            )
            return exists && FilesLocation.isListed(name, isDirectory: isDirectory.boolValue, in: path)
        }
    }

    var itemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(path) }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        path.parent.map(NSFileProviderItemIdentifier.init) ?? .rootContainer
    }

    var filename: String { path.isRoot ? "Wye" : path.name }

    var contentType: UTType { type }

    var capabilities: NSFileProviderItemCapabilities {
        let permissions = FilesPermissions.of(path)
        var capabilities: NSFileProviderItemCapabilities = []
        if permissions.contains(.read) { capabilities.insert(.allowsReading) }
        if permissions.contains(.write), isWritable, !isLink { capabilities.insert(.allowsWriting) }
        if permissions.contains(.rename) { capabilities.insert(.allowsRenaming) }
        if permissions.contains(.move) { capabilities.insert(.allowsReparenting) }
        if permissions.contains(.delete) { capabilities.insert(.allowsDeleting) }
        return capabilities
    }

    var documentSize: NSNumber? { size.map { NSNumber(value: $0) } }
    var childItemCount: NSNumber? { children.map { NSNumber(value: $0) } }
    var creationDate: Date? { created }
    var contentModificationDate: Date? { modified }

    // The files are on the device: nothing to upload or download.
    var isUploaded: Bool { true }
    var isDownloaded: Bool { true }
    var isMostRecentVersionDownloaded: Bool { true }

    /// Changes when the contents do, so the system knows to read them again.
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: version, metadataVersion: version)
    }

    /// What the change listing compares: the item's time and size.
    var version: Data {
        let stamp = "\(modified?.timeIntervalSinceReferenceDate ?? 0)|\(size ?? -1)|\(children ?? -1)"
        return Data(stamp.utf8)
    }
}
