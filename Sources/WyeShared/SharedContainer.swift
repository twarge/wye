import Foundation

/// The folder the app and its extensions share.
public enum SharedContainer {
    /// The app group on iOS. The Mac uses the team-prefixed form, which a
    /// sandboxed Mac app may use without a provisioning profile, so local
    /// builds work before the group is registered.
    public static let iOSGroupIdentifier = "group.com.twarge.app.wye"
    public static let macOSGroupIdentifier = "257KW9ZJFP.com.twarge.app.wye"

    public static var groupIdentifier: String {
        #if os(macOS)
        macOSGroupIdentifier
        #else
        iOSGroupIdentifier
        #endif
    }

    /// Overrides the folder; tests point it at a temporary one.
    nonisolated(unsafe) public static var directoryOverride: URL?

    /// The app group's container when there is one, otherwise Application
    /// Support, which is enough for the app alone (in tests, say).
    public static var directory: URL {
        if let directoryOverride { return directoryOverride }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
            ?? URL.applicationSupportDirectory.appending(path: "Wye", directoryHint: .isDirectory)
    }
}

/// An address the share extension passes to the app to clone. The
/// extension cannot open the app itself, so it leaves the address here and
/// the app picks it up when it next comes to the front.
public enum PendingClone {
    static let fileName = "PendingClone.txt"

    static var fileURL: URL { SharedContainer.directory.appending(path: fileName) }

    public static func leave(_ address: String) throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(address.utf8).write(to: url, options: .atomic)
    }

    /// The address waiting, removed so it is offered only once. Ignores one
    /// left more than an hour ago, which the user has moved on from.
    public static func take(now: Date = .now) -> String? {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        try? FileManager.default.removeItem(at: url)
        if let modified, now.timeIntervalSince(modified) > 3600 { return nil }
        let address = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? nil : address
    }
}
