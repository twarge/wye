import AppIntents
import Foundation
#if canImport(Darwin)
import notify
#endif

/// What a widget or a Control Center control can ask the app to do.
public enum WidgetAction: Codable, Hashable, Sendable {
    case fetchAll
    case fetch(UUID)
    case pull(UUID)
}

/// Carries a widget's request to the app. A widget has no git of its own:
/// the app does the work and the widget shows the status file it writes.
///
/// The intents below are in the app and in the widget extension alike. Run
/// in the app's process, `handler` is set and does the work at once. Run in
/// the extension's, there is none, and the request is left in the shared
/// container for the app: at once if it is running, which a notification
/// tells it, otherwise when it next comes to the front.
public enum WidgetActions {
    /// Set by the app as it starts.
    @MainActor public static var handler: (@MainActor (WidgetAction) async -> Void)?

    /// Posted when a request is left, so an app that is running takes it
    /// up at once rather than when it next comes to the front.
    public static let pendingNotification = "com.twarge.app.wye.widget-action"

    static let fileName = "PendingWidgetActions.json"
    static var fileURL: URL { SharedContainer.directory.appending(path: fileName) }

    /// How long a request left for the app stays worth doing.
    public static let lifetime: TimeInterval = 15 * 60

    @MainActor
    public static func perform(_ action: WidgetAction) async {
        if let handler {
            await handler(action)
        } else {
            leave(action)
        }
    }

    private struct Pending: Codable {
        var action: WidgetAction
        var date: Date
    }

    /// Adds a request to those waiting, once: asking twice is one request.
    public static func leave(_ action: WidgetAction, now: Date = .now) {
        var pending = read().filter { $0.action != action }
        pending.append(Pending(action: action, date: now))
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pending).write(to: url, options: .atomic)
        // Not for a folder a test pointed the container at.
        guard SharedContainer.directoryOverride == nil else { return }
        #if canImport(Darwin)
        notify_post(pendingNotification)
        #endif
    }

    /// The requests waiting, oldest first, removed so each is done once.
    /// Those left longer ago than `lifetime` are dropped: the user has
    /// moved on, and a pull out of nowhere would be a surprise.
    public static func take(now: Date = .now) -> [WidgetAction] {
        let pending = read()
        guard !pending.isEmpty else { return [] }
        try? FileManager.default.removeItem(at: fileURL)
        return pending.filter { now.timeIntervalSince($0.date) <= lifetime }.map(\.action)
    }

    private static func read() -> [Pending] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }
}

/// Lets the app and the widget extension take in these intents' metadata.
public struct WyeSharedIntentsPackage: AppIntentsPackage {}

// On iOS the intents are Live Activity intents, which is what has the
// system run them in the app's process, where the work can be done, rather
// than in the widget extension's.
#if os(iOS)
public typealias WidgetIntent = LiveActivityIntent
#else
public typealias WidgetIntent = AppIntent
#endif

/// A repository as a widget's configuration offers it: read from the status
/// file, so the extension needs neither the app nor its list.
public struct WidgetRepository: AppEntity {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Repository" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public static var defaultQuery: WidgetRepositoryQuery { WidgetRepositoryQuery() }
}

public struct WidgetRepositoryQuery: EntityStringQuery {
    public init() {}

    private func all() -> [WidgetRepository] {
        SharedStatusStore.load().map { WidgetRepository(id: $0.id, name: $0.name) }
    }

    public func entities(for identifiers: [UUID]) async throws -> [WidgetRepository] {
        all().filter { identifiers.contains($0.id) }
    }

    public func entities(matching string: String) async throws -> [WidgetRepository] {
        all().filter { $0.name.localizedStandardContains(string) }
    }

    public func suggestedEntities() async throws -> [WidgetRepository] {
        all()
    }
}

/// Fetches every repository, from a widget's button or a control.
public struct WidgetFetchAllIntent: WidgetIntent {
    public static var title: LocalizedStringResource { "Fetch All Repositories" }
    public static var description: IntentDescription {
        IntentDescription("Fetches every repository in Wye.")
    }
    public static var isDiscoverable: Bool { false }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await WidgetActions.perform(.fetchAll)
        return .result()
    }
}

/// Fetches one repository, from its widget's button.
public struct WidgetFetchIntent: WidgetIntent {
    public static var title: LocalizedStringResource { "Fetch" }
    public static var isDiscoverable: Bool { false }

    @Parameter(title: "Repository")
    public var repository: String

    public init() {}

    public init(repository: UUID) {
        self.repository = repository.uuidString
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: repository) {
            await WidgetActions.perform(.fetch(id))
        }
        return .result()
    }
}

/// Pulls one repository, from its widget's button.
public struct WidgetPullIntent: WidgetIntent {
    public static var title: LocalizedStringResource { "Pull" }
    public static var isDiscoverable: Bool { false }

    @Parameter(title: "Repository")
    public var repository: String

    public init() {}

    public init(repository: UUID) {
        self.repository = repository.uuidString
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: repository) {
            await WidgetActions.perform(.pull(id))
        }
        return .result()
    }
}

/// Which repository a Repository widget shows.
public struct RepositoryWidgetConfiguration: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource { "Repository" }
    public static var description: IntentDescription {
        IntentDescription("Shows one repository’s branch and what it has to push, pull and commit.")
    }

    @Parameter(title: "Repository")
    public var repository: WidgetRepository?

    public init() {}
}
