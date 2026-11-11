import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What the app knows about one listed repository, published for the widgets
/// (and anything else outside the app's process) to read. Kept deliberately
/// small and flat so a widget can decode it without GitKit.
public struct RepositoryStatusSummary: Codable, Hashable, Sendable, Identifiable {
    /// The repository list's bookmark id.
    public var id: UUID
    public var name: String
    /// The checked-out branch, nil when detached or unborn.
    public var branch: String?
    /// Commits on the branch that its upstream does not have (unpushed).
    public var ahead: Int
    /// Commits on the upstream that the branch does not have.
    public var behind: Int
    public var hasUncommittedChanges: Bool
    public var updated: Date

    public init(
        id: UUID,
        name: String,
        branch: String?,
        ahead: Int,
        behind: Int,
        hasUncommittedChanges: Bool,
        updated: Date
    ) {
        self.id = id
        self.name = name
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.hasUncommittedChanges = hasUncommittedChanges
        self.updated = updated
    }
}

/// One JSON file of `RepositoryStatusSummary`, in the app group container
/// when the app has one (so the widget extension can read it) and in
/// Application Support otherwise.
public enum SharedStatusStore {
    /// The app group the file is shared through on this platform.
    public static var appGroupIdentifier: String { SharedContainer.groupIdentifier }
    static let fileName = "RepositoryStatus.json"

    /// Overrides the file's location; tests point it at a temporary folder.
    nonisolated(unsafe) public static var fileURLOverride: URL?

    public static var fileURL: URL {
        fileURLOverride ?? SharedContainer.directory.appending(path: fileName)
    }

    /// The last summaries saved, or none when nothing was saved or the file
    /// cannot be read (a widget then shows its empty state).
    public static func load() -> [RepositoryStatusSummary] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([RepositoryStatusSummary].self, from: data)) ?? []
    }

    /// Replaces the file with these summaries, atomically so a reader never
    /// sees half a file.
    public static func save(_ summaries: [RepositoryStatusSummary]) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try encoder.encode(summaries)
            try data.write(to: url, options: .atomic)
            // The widgets read the file again only when told to. Not for a
            // file a test put somewhere else.
            if fileURLOverride == nil {
                reloadWidgets()
            }
        } catch {
            // A widget showing slightly stale status is not worth an alert.
        }
    }

    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
