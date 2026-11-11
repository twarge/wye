import Foundation
import GitKit

/// The filters on a history beside its search text: a range of dates,
/// authors, and branches to show only or to hide. Each shows as a token in
/// the search field, where deleting the token removes it.
struct HistoryFilters: Hashable {
    var since: Date?
    var until: Date?
    var authors: Set<HistoryFilter.Author> = []
    /// Branches, by full reference name, whose commits alone are listed.
    var shownBranches: [String] = []
    /// Branches, by full reference name, whose commits are left out.
    var hiddenBranches: [String] = []

    var isEmpty: Bool { self == HistoryFilters() }

    /// The part the engine applies commit by commit. When it is not empty,
    /// the list shows matching commits without the graph, as a search does.
    var commitFilter: HistoryFilter {
        HistoryFilter(since: since, until: until, authors: authors)
    }

    /// The part that changes which commits the history walks, so the graph
    /// still holds.
    func applied(to options: HistoryOptions) -> HistoryOptions {
        var options = options
        options.includedReferences = shownBranches
        options.hiddenReferences = hiddenBranches
        return options
    }

    // MARK: Tokens

    enum Token: Identifiable, Hashable {
        case since(Date)
        case until(Date)
        case author(HistoryFilter.Author)
        case shownBranch(String)
        case hiddenBranch(String)

        var id: Self { self }

        @MainActor var title: String {
            switch self {
            case .since(let date): "Since \(date.formatted(date: .abbreviated, time: .omitted))"
            case .until(let date): "Until \(date.formatted(date: .abbreviated, time: .omitted))"
            case .author(let author): author.name.isEmpty ? author.email : author.name
            case .shownBranch(let name): RepositoryModel.displayName(ofReference: name)
            case .hiddenBranch(let name): "Not \(RepositoryModel.displayName(ofReference: name))"
            }
        }

        var systemImage: String {
            switch self {
            case .since, .until: "calendar"
            case .author: "person"
            case .shownBranch: "arrow.triangle.branch"
            case .hiddenBranch: "eye.slash"
            }
        }
    }

    /// The filters as the search field's tokens, in a steady order.
    var tokens: [Token] {
        var tokens: [Token] = []
        if let since { tokens.append(.since(since)) }
        if let until { tokens.append(.until(until)) }
        tokens += authors.sorted().map(Token.author)
        tokens += shownBranches.map(Token.shownBranch)
        tokens += hiddenBranches.map(Token.hiddenBranch)
        return tokens
    }

    /// Keeps only the filters still among `tokens`: the field's tokens
    /// after one was deleted.
    func keeping(_ tokens: [Token]) -> HistoryFilters {
        let kept = Set(tokens)
        var filters = self
        if let since, !kept.contains(.since(since)) { filters.since = nil }
        if let until, !kept.contains(.until(until)) { filters.until = nil }
        filters.authors = authors.filter { kept.contains(.author($0)) }
        filters.shownBranches = shownBranches.filter { kept.contains(.shownBranch($0)) }
        filters.hiddenBranches = hiddenBranches.filter { kept.contains(.hiddenBranch($0)) }
        return filters
    }

    // MARK: Changing

    mutating func toggle(_ author: HistoryFilter.Author) {
        if authors.contains(author) { authors.remove(author) } else { authors.insert(author) }
    }

    /// Showing a branch stops it being hidden, and the other way round.
    mutating func toggleShown(_ branch: String) {
        if shownBranches.contains(branch) {
            shownBranches.removeAll { $0 == branch }
        } else {
            shownBranches.append(branch)
            hiddenBranches.removeAll { $0 == branch }
        }
    }

    mutating func toggleHidden(_ branch: String) {
        if hiddenBranches.contains(branch) {
            hiddenBranches.removeAll { $0 == branch }
        } else {
            hiddenBranches.append(branch)
            shownBranches.removeAll { $0 == branch }
        }
    }

    /// The ranges the date menu offers, ending now.
    enum RecentRange: CaseIterable, Identifiable {
        case day, week, month, year

        var id: Self { self }

        var title: String {
            switch self {
            case .day: "Last 24 Hours"
            case .week: "Last 7 Days"
            case .month: "Last 30 Days"
            case .year: "Last 12 Months"
            }
        }

        func start(before now: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .day: now.addingTimeInterval(-24 * 60 * 60)
            case .week: calendar.date(byAdding: .day, value: -7, to: now) ?? now
            case .month: calendar.date(byAdding: .day, value: -30, to: now) ?? now
            case .year: calendar.date(byAdding: .month, value: -12, to: now) ?? now
            }
        }
    }

    /// The authors of `commits`, those with most commits first, as the
    /// author menu offers them.
    static func authors(of commits: some Sequence<Commit>, limit: Int = 40) -> [HistoryFilter.Author] {
        var counts: [HistoryFilter.Author: Int] = [:]
        for commit in commits {
            counts[HistoryFilter.Author(name: commit.author.name, email: commit.author.email), default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }
}
