import Foundation

/// A named group in the repository list.
struct RepositoryGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}

/// The repository list as saved. The first versions saved only the array of
/// repositories, which still reads: as the repositories, with no groups.
struct LibraryFile: Codable, Equatable {
    var version = 2
    var repositories: [RepositoryBookmark]
    var groups: [RepositoryGroup]

    init(repositories: [RepositoryBookmark], groups: [RepositoryGroup]) {
        self.repositories = repositories
        self.groups = groups
    }

    static func decode(_ data: Data) throws -> LibraryFile {
        let decoder = JSONDecoder()
        if let repositories = try? decoder.decode([RepositoryBookmark].self, from: data) {
            return LibraryFile(repositories: repositories, groups: [])
        }
        return try decoder.decode(LibraryFile.self, from: data)
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// How the repository list orders the repositories within each group.
enum RepositoryListOrder: String, CaseIterable, Identifiable {
    case name
    case lastOpened

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .lastOpened: "Last Opened"
        }
    }

    func sorted(_ bookmarks: [RepositoryBookmark]) -> [RepositoryBookmark] {
        switch self {
        case .name:
            bookmarks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastOpened:
            bookmarks.sorted { lhs, rhs in
                let left = lhs.lastOpened ?? .distantPast
                let right = rhs.lastOpened ?? .distantPast
                if left != right { return left > right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
