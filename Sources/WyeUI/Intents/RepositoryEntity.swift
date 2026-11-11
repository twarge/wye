import AppIntents
import CoreSpotlight
import Foundation

/// A repository in Wye's list, as Siri, Shortcuts and Spotlight see it.
public struct RepositoryEntity: AppEntity, IndexedEntity {
    public let id: UUID
    public let name: String
    /// Where it is, for telling two of the same name apart.
    public let location: String?

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Repository", numericFormat: "\(placeholder: .int) repositories")
    }

    public var displayRepresentation: DisplayRepresentation {
        if let location {
            DisplayRepresentation(title: "\(name)", subtitle: "\(location)", image: .init(systemName: "folder"))
        } else {
            DisplayRepresentation(title: "\(name)", image: .init(systemName: "folder"))
        }
    }

    public static var defaultQuery: RepositoryQuery { RepositoryQuery() }

    @MainActor
    init(_ bookmark: RepositoryBookmark, in library: RepositoryLibrary) {
        id = bookmark.id
        name = bookmark.name
        location = library.path(of: bookmark)
    }
}

/// Finds repositories by id, and by name for what someone said or typed.
public struct RepositoryQuery: EntityStringQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [UUID]) async throws -> [RepositoryEntity] {
        let library = RepositoryLibrary.shared
        return identifiers.compactMap { id in
            library.bookmarks.first { $0.id == id }.map { RepositoryEntity($0, in: library) }
        }
    }

    @MainActor
    public func entities(matching string: String) async throws -> [RepositoryEntity] {
        let library = RepositoryLibrary.shared
        return RepositoryMatching.matches(string, in: library.listedBookmarks, name: \.name)
            .map { RepositoryEntity($0, in: library) }
    }

    @MainActor
    public func suggestedEntities() async throws -> [RepositoryEntity] {
        let library = RepositoryLibrary.shared
        return library.listedBookmarks.map { RepositoryEntity($0, in: library) }
    }
}

/// How one repository stands, as Get Repository Status returns it.
public struct RepositoryStatusEntity: TransientAppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Repository Status" }

    @Property(title: "Repository")
    public var name: String
    /// The checked-out branch; empty when `HEAD` is detached.
    @Property(title: "Branch")
    public var branch: String?
    @Property(title: "Commits Ahead")
    public var ahead: Int
    @Property(title: "Commits Behind")
    public var behind: Int
    @Property(title: "Changed Files")
    public var changedFiles: Int
    /// The sentence Siri says.
    @Property(title: "Summary")
    public var summary: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
    }

    public init() {
        name = ""
        branch = nil
        ahead = 0
        behind = 0
        changedFiles = 0
        summary = ""
    }
}
