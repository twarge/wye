import Foundation
import GitKit

/// What quick open is choosing for.
enum QuickOpenPurpose: Identifiable, Hashable {
    /// Go to a branch, remote branch or tag in the sidebar, or open another
    /// repository in this window.
    case jump
    /// Choose what to merge into the current branch, then confirm in the merge sheet.
    case merge
    /// Choose what to rebase the current branch onto, then confirm in the rebase sheet.
    case rebase

    var id: Self { self }

    var prompt: String {
        switch self {
        case .jump: "Branch, tag or repository"
        case .merge: "Branch or tag to merge"
        case .rebase: "Branch to rebase onto"
        }
    }

    func title(currentBranch: String?) -> String {
        let current = currentBranch.map { "“\($0)”" } ?? "the Current Branch"
        return switch self {
        case .jump: "Quick Open"
        case .merge: "Merge into \(current)"
        case .rebase: "Rebase \(current) onto"
        }
    }
}

/// Something quick open can go to.
struct QuickOpenItem: Identifiable, Hashable {
    enum Target: Hashable {
        /// A local branch, by full reference name.
        case branch(String)
        case remoteBranch(String)
        case tag(String)
        case repository(RepositoryBookmark)
    }

    var target: Target
    /// The name typed against: a branch's short name, a repository's name.
    var title: String
    var detail: String

    var id: String {
        switch target {
        case .branch(let name), .remoteBranch(let name), .tag(let name): name
        case .repository(let bookmark): "repository:\(bookmark.id.uuidString)"
        }
    }

    var systemImage: String {
        switch target {
        case .branch: "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        case .repository: "folder"
        }
    }

    /// The references in a snapshot, and the repositories in the library,
    /// that suit a purpose. Repositories come most recently opened first.
    static func items(
        for purpose: QuickOpenPurpose,
        snapshot: RepositorySnapshot?,
        repositories: [RepositoryBookmark] = [],
        currentRepository: UUID? = nil
    ) -> [QuickOpenItem] {
        var items: [QuickOpenItem] = []
        if let snapshot {
            let head = snapshot.head.branchName
            for branch in snapshot.branches where purpose == .jump || branch.id != head {
                let detail = branch.id == head ? "Current branch" : branch.upstream.map { "Tracks \($0.name)" } ?? "Branch"
                items.append(QuickOpenItem(target: .branch(branch.id), title: branch.name, detail: detail))
            }
            for branch in snapshot.remotes.flatMap(\.branches) where branch.nameWithoutRemote != "HEAD" {
                items.append(QuickOpenItem(target: .remoteBranch(branch.id), title: branch.name, detail: "Remote branch"))
            }
            if purpose != .rebase {
                for tag in snapshot.tags {
                    items.append(QuickOpenItem(target: .tag(tag.id), title: tag.name, detail: "Tag"))
                }
            }
        }
        if purpose == .jump {
            let recent = repositories.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            for bookmark in recent {
                let detail = bookmark.id == currentRepository ? "This repository" : "Repository"
                items.append(QuickOpenItem(target: .repository(bookmark), title: bookmark.name, detail: detail))
            }
        }
        return items
    }

    /// The items that match a query, best first. Equally good matches put
    /// the shorter name first, then keep their order. With nothing typed,
    /// every item, in the order given.
    static func rank(_ items: [QuickOpenItem], query: String) -> [(item: QuickOpenItem, match: FuzzyMatch)] {
        guard !query.allSatisfy(\.isWhitespace) else {
            return items.map { ($0, FuzzyMatch(score: 0, offsets: [])) }
        }
        return items.enumerated()
            .compactMap { offset, item in
                FuzzyMatcher.match(query, in: item.title).map { (offset: offset, item: item, match: $0) }
            }
            .sorted { lhs, rhs in
                if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
                if lhs.item.title.count != rhs.item.title.count { return lhs.item.title.count < rhs.item.title.count }
                return lhs.offset < rhs.offset
            }
            .map { ($0.item, $0.match) }
    }
}
