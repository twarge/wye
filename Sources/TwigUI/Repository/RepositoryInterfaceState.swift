import Foundation
import GitKit
import Observation

/// How one repository's branches are laid out in the sidebar: which are
/// pinned to the top, which are archived out of the way, and which opt out
/// of automatic archiving or of the "merged" mark. Branches are named by
/// their full reference names.
///
/// This is Twig's own interface state, so it is kept in the app's folder,
/// a file per repository named by its bookmark, as the undo history is:
/// never in the repository, where it could reach a push, show up for other
/// tools, or be shared between worktrees that want different layouts.
@MainActor
@Observable
final class RepositoryInterfaceState {
    struct Stored: Codable, Equatable {
        var version = 1
        var pinned: [String] = []
        var archived: [String] = []
        var skipsAutoArchiving: [String] = []
        var hidesMergedMark: [String] = []
    }

    private(set) var stored = Stored()
    /// How the branches stand against the main branch, for the merged and
    /// stale marks, and the branches it was worked out for.
    private(set) var review: BranchReview?
    private var reviewedKey: ReviewKey?
    private let storage: URL?

    /// - Parameter storage: Where the state is kept; `nil` keeps it in memory.
    init(storage: URL?) {
        self.storage = storage
        load()
    }

    /// The state kept for a repository in the app's own folder.
    convenience init(repositoryID: UUID) {
        self.init(storage: .applicationSupportDirectory.appending(path: "Twig/Interface/\(repositoryID.uuidString).json"))
    }

    func isPinned(_ branch: String) -> Bool { stored.pinned.contains(branch) }
    func isArchivedByHand(_ branch: String) -> Bool { stored.archived.contains(branch) }
    func skipsAutoArchiving(_ branch: String) -> Bool { stored.skipsAutoArchiving.contains(branch) }
    func hidesMergedMark(_ branch: String) -> Bool { stored.hidesMergedMark.contains(branch) }

    /// Pinning takes a branch out of the archive, and archiving unpins it:
    /// a branch is in one place.
    func setPinned(_ branch: String, _ isPinned: Bool) {
        update {
            $0.pinned.set(branch, isPinned)
            if isPinned { $0.archived.set(branch, false) }
        }
    }

    func setArchived(_ branch: String, _ isArchived: Bool) {
        update {
            $0.archived.set(branch, isArchived)
            if isArchived { $0.pinned.set(branch, false) }
        }
    }

    /// Unarchives a branch, wherever its archiving came from: one that was
    /// archived for its age stops being archived automatically, or it would
    /// go straight back.
    func unarchive(_ branch: String, wasAutomatic: Bool) {
        update {
            $0.archived.set(branch, false)
            if wasAutomatic { $0.skipsAutoArchiving.set(branch, true) }
        }
    }

    func setSkipsAutoArchiving(_ branch: String, _ skips: Bool) {
        update { $0.skipsAutoArchiving.set(branch, skips) }
    }

    func setHidesMergedMark(_ branch: String, _ hides: Bool) {
        update { $0.hidesMergedMark.set(branch, hides) }
    }

    /// A renamed branch keeps its pin and flags.
    func renamed(_ branch: String, to newName: String) {
        guard branch != newName else { return }
        update { stored in
            for keyPath in Self.lists where stored[keyPath: keyPath].contains(branch) {
                stored[keyPath: keyPath].set(branch, false)
                stored[keyPath: keyPath].set(newName, true)
            }
        }
    }

    /// Forgets a deleted branch, so a new branch of the same name starts
    /// afresh.
    func forget(_ branch: String) {
        update { stored in
            for keyPath in Self.lists {
                stored[keyPath: keyPath].set(branch, false)
            }
        }
    }

    private static let lists: [WritableKeyPath<Stored, [String]>] = [
        \.pinned, \.archived, \.skipsAutoArchiving, \.hidesMergedMark
    ]

    // MARK: Review

    /// What a review depends on: the branches and the remote branches,
    /// whose `origin/HEAD` can name the main branch.
    struct ReviewKey: Hashable {
        var branches: [Branch]
        var remotes: [Remote]
    }

    func needsReview(of snapshot: RepositorySnapshot) -> Bool {
        reviewedKey != ReviewKey(branches: snapshot.branches, remotes: snapshot.remotes)
    }

    func take(_ review: BranchReview, for snapshot: RepositorySnapshot) {
        self.review = review
        reviewedKey = ReviewKey(branches: snapshot.branches, remotes: snapshot.remotes)
    }

    // MARK: Storage

    private func update(_ change: (inout Stored) -> Void) {
        var copy = stored
        change(&copy)
        guard copy != stored else { return }
        stored = copy
        save()
    }

    private func load() {
        guard let storage, let data = try? Data(contentsOf: storage),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data), decoded.version == 1 else { return }
        stored = decoded
    }

    private func save() {
        guard let storage else { return }
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: storage, options: .atomic)
        } catch {
            // The layout still holds for this session; it just won't be
            // there next time.
        }
    }
}

private extension Array where Element == String {
    /// Adds or removes a name, keeping the order names were added in.
    mutating func set(_ name: String, _ isMember: Bool) {
        if isMember {
            if !contains(name) { append(name) }
        } else {
            removeAll { $0 == name }
        }
    }
}

// MARK: Listing

/// The app's settings for marking and archiving branches, in the user
/// defaults.
enum BranchPreferences {
    static let staleMonthsKey = "branches.staleMonths"
    static let autoArchiveMonthsKey = "branches.autoArchiveMonths"

    /// Months without a commit after which a branch is marked stale; 0 for never.
    static var staleMonths: Int {
        UserDefaults.standard.object(forKey: staleMonthsKey) as? Int ?? 3
    }

    /// Months without a commit after which a branch is archived; 0, the
    /// default, for never.
    static var autoArchiveMonths: Int {
        UserDefaults.standard.integer(forKey: autoArchiveMonthsKey)
    }

    static let staleChoices = [1, 2, 3, 6, 12, 0]
    static let autoArchiveChoices = [0, 3, 6, 12, 24]
}

/// The sidebar's branches, sorted into where they show, with the marks
/// each gets. Pure, so that it can be tested without a window.
struct BranchListing {
    struct Marks: Hashable {
        var isPinned = false
        var isMerged = false
        var isStale = false
        /// Archived for its age rather than by hand.
        var isAutoArchived = false
    }

    /// Pinned branches, at the top, in the order the branches came.
    var pinned: [Branch] = []
    /// Everything else that is not archived.
    var listed: [Branch] = []
    var archived: [Branch] = []
    var marks: [String: Marks] = [:]

    init(
        branches: [Branch],
        state: RepositoryInterfaceState.Stored,
        review: BranchReview?,
        now: Date = .now,
        staleMonths: Int = BranchPreferences.staleMonths,
        autoArchiveMonths: Int = BranchPreferences.autoArchiveMonths,
        calendar: Calendar = .current
    ) {
        let pinned = Set(state.pinned)
        let archived = Set(state.archived)
        let skips = Set(state.skipsAutoArchiving)
        let hidesMerged = Set(state.hidesMergedMark)
        let staleBefore = staleMonths > 0 ? calendar.date(byAdding: .month, value: -staleMonths, to: now) : nil
        let archiveBefore = autoArchiveMonths > 0
            ? calendar.date(byAdding: .month, value: -autoArchiveMonths, to: now) : nil

        for branch in branches {
            let tip = review?.tipDates[branch.id]
            var marks = Marks()
            marks.isPinned = pinned.contains(branch.id)
            marks.isMerged = review?.merged.contains(branch.id) == true && !hidesMerged.contains(branch.id)
                && !branch.isHead
            marks.isStale = !branch.isHead && Self.isOlder(tip, than: staleBefore)
            // The checked-out branch always shows where it can be seen.
            let byHand = archived.contains(branch.id)
            let byAge = !byHand && !marks.isPinned && !skips.contains(branch.id) && Self.isOlder(tip, than: archiveBefore)
            if !branch.isHead && (byHand || byAge) {
                marks.isAutoArchived = byAge
                self.archived.append(branch)
            } else if marks.isPinned {
                self.pinned.append(branch)
            } else {
                listed.append(branch)
            }
            self.marks[branch.id] = marks
        }
    }

    private static func isOlder(_ date: Date?, than limit: Date?) -> Bool {
        guard let date, let limit else { return false }
        return date < limit
    }
}
