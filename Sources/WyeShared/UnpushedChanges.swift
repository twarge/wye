import Foundation

extension RepositoryStatusSummary {
    /// Whether it has work that is only on this device: commits its
    /// upstream lacks, or changes not committed.
    public var hasUnpushedWork: Bool {
        ahead > 0 || hasUncommittedChanges
    }
}

/// What the Unpushed Changes widget lists.
public struct UnpushedChanges: Hashable, Sendable {
    /// The repositories to show, most recently updated first.
    public var repositories: [RepositoryStatusSummary]
    /// How many repositories have unpushed work, shown or not.
    public var total: Int

    public static let limit = 5

    /// The repositories with unpushed work, most recently updated first,
    /// at most `limit` of them. Ties go by name so the order holds still.
    public init(_ summaries: [RepositoryStatusSummary], limit: Int = Self.limit) {
        let unpushed = summaries.filter(\.hasUnpushedWork).sorted { first, second in
            if first.updated != second.updated { return first.updated > second.updated }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
        repositories = Array(unpushed.prefix(max(0, limit)))
        total = unpushed.count
    }

    public var isEmpty: Bool { total == 0 }
}

extension RepositoryStatusSummary {
    /// "2 unpushed, changes": the counts a widget row shows, shortest first.
    public var unpushedDescription: String {
        var parts: [String] = []
        if ahead > 0 { parts.append("\(ahead) unpushed") }
        if behind > 0 { parts.append("\(behind) behind") }
        if hasUncommittedChanges { parts.append("uncommitted changes") }
        return parts.joined(separator: ", ")
    }
}
