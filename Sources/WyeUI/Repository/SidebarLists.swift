import Foundation
import GitKit

/// How the sidebar orders a long list.
enum SidebarSort: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A to Z, as text: `v1.10` before `v1.9`.
    case name
    /// Highest version first: `v1.10` before `v1.9`, and a release before
    /// its release candidates.
    case version
    /// The newest commit first.
    case recent

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .version: "Version"
        case .recent: "Most Recent First"
        }
    }

    /// Orders `items`, ties going by name. `date` is only asked for `.recent`.
    func sorted<Item>(_ items: [Item], name: (Item) -> String, date: (Item) -> Date?) -> [Item] {
        switch self {
        case .name:
            return items.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
        case .version:
            return items.sorted { VersionOrder.precedes(name($1), name($0)) }
        case .recent:
            let dated = items.map { (item: $0, date: date($0) ?? .distantPast, name: name($0)) }
            return dated.sorted {
                $0.date != $1.date ? $0.date > $1.date
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }.map(\.item)
        }
    }
}

/// Compares names as versions: runs of digits by their value, and a
/// pre-release (`1.2.0-rc1`) before its release (`1.2.0`).
enum VersionOrder {
    private enum Part: Equatable {
        case number(Int)
        case text(String)
    }

    /// Whether `lhs` comes before `rhs` going up.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let left = parts(lhs), right = parts(rhs)
        for index in 0..<max(left.count, right.count) {
            var a = index < left.count ? left[index] : nil
            var b = index < right.count ? right[index] : nil
            // A missing number counts as 0: `1.10` is `1.10.0`.
            if a == nil, case .number = b { a = .number(0) }
            if b == nil, case .number = a { b = .number(0) }
            // One is the other with more after it. A pre-release suffix
            // (`-rc1`) makes it earlier; anything else later.
            guard let a else { return b.map { !isPreRelease($0) } ?? false }
            guard let b else { return isPreRelease(a) }
            guard a != b else { continue }
            switch (a, b) {
            case (.number(let x), .number(let y)): return x < y
            // Text sorts before a number in the same place.
            case (.number, .text): return false
            case (.text, .number): return true
            case (.text(let x), .text(let y)):
                return x.localizedCaseInsensitiveCompare(y) == .orderedAscending
            }
        }
        return lhs < rhs
    }

    private static func isPreRelease(_ part: Part) -> Bool {
        if case .text(let text) = part { return text.hasPrefix("-") || text.hasPrefix("~") }
        return false
    }

    private static func parts(_ name: String) -> [Part] {
        var parts: [Part] = []
        var current = ""
        var isDigits = false
        func flush() {
            guard !current.isEmpty else { return }
            parts.append(isDigits ? .number(Int(current.prefix(18)) ?? 0) : .text(current))
            current = ""
        }
        for character in name {
            let digit = character.isASCII && character.isNumber
            if digit != isDigits { flush() }
            isDigits = digit
            current.append(character)
        }
        flush()
        // The dots between numbers say nothing on their own.
        return parts.filter { $0 != .text(".") }
    }
}

/// The sidebar's sorting and shortening choices, kept per repository.
struct SidebarListOptions: Codable, Hashable, Sendable {
    var tagSort: SidebarSort = .recent
    var remoteBranchSort: SidebarSort = .recent
    var showsAllTags = false
    /// Remotes whose branches are all listed, by name.
    var remotesShowingAll: [String] = []

    /// How many rows a long list shows before its Show All row.
    static let limit = 30

    init() {}

    private enum CodingKeys: String, CodingKey {
        case tagSort, remoteBranchSort, showsAllTags, remotesShowingAll
    }

    /// Reads what it can, so a choice added later does not lose the others.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagSort = (try? container.decodeIfPresent(SidebarSort.self, forKey: .tagSort)) ?? .recent
        remoteBranchSort = (try? container.decodeIfPresent(SidebarSort.self, forKey: .remoteBranchSort)) ?? .recent
        showsAllTags = (try? container.decodeIfPresent(Bool.self, forKey: .showsAllTags)) ?? false
        remotesShowingAll = (try? container.decodeIfPresent([String].self, forKey: .remotesShowingAll)) ?? []
    }
}

/// The first `limit` of a list, unless all are wanted, and how many more
/// there are.
struct Shortened<Item> {
    var shown: [Item]
    var hiddenCount: Int

    init(_ items: [Item], showsAll: Bool, limit: Int = SidebarListOptions.limit) {
        // Not worth a Show All row for a handful more.
        if showsAll || items.count <= limit + 5 {
            shown = items
            hiddenCount = 0
        } else {
            shown = Array(items.prefix(limit))
            hiddenCount = items.count - limit
        }
    }
}

/// Typing in the sidebar's filter field narrows its lists.
enum SidebarFilter {
    /// Whether `name` matches what was typed: every word of it, anywhere,
    /// ignoring case and accents.
    static func matches(_ name: String, _ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { name.localizedStandardContains($0) }
    }

    /// The ids of the folders in `nodes`, at every depth, that are closed
    /// unless toggled: all but those holding the checked-out branch. While
    /// filtering, toggling these opens every folder, so every match shows.
    static func closedFolders(in nodes: [BranchFolderNode], headBranch: String?) -> Set<String> {
        var ids: Set<String> = []
        for node in nodes where node.branch == nil {
            if !(headBranch.map(node.contains) ?? false) { ids.insert(node.id) }
            ids.formUnion(closedFolders(in: node.children, headBranch: headBranch))
        }
        return ids
    }
}
