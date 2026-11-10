import Foundation
import GitKit
import Observation

/// What the sidebar can select.
enum SidebarItem: Hashable {
    case workingCopy
    case history
    case stashes
    /// Where `HEAD` or a branch has pointed.
    case reflog
    /// A local branch, by its full reference name.
    case branch(String)
    case remoteBranch(String)
    case tag(String)
    case submodule(String)
    case worktree(String)

    /// The history this item lists, for the items that list one.
    var historyScope: HistoryScope? {
        switch self {
        case .history: .allReferences
        case .branch(let name), .remoteBranch(let name), .tag(let name): .reference(name)
        case .workingCopy, .stashes, .reflog, .submodule, .worktree: nil
        }
    }
}

/// A reference name shown beside the commit it points at.
struct RefLabel: Identifiable, Hashable {
    enum Kind: Hashable {
        case head
        case branch
        case tag
        case remote
    }

    var name: String
    var kind: Kind

    var id: Self { self }
}

/// The working copy's changes and the commit being written.
struct WorkingCopyState {
    var entries: [StatusEntry] = []
    var selection: String?
    var subject = ""
    var details = ""
    var identity: GitIdentity?
    /// Set while the composer amends the last commit.
    var amend: AmendDraft?

    var hasStagedChanges: Bool {
        entries.contains { $0.staged != nil }
    }

    var canCommit: Bool {
        hasStagedChanges && identity != nil && !subject.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// One open repository: the state behind a repository window.
@MainActor
@Observable
final class RepositoryModel: Identifiable {
    let bookmark: RepositoryBookmark
    let repository: Repository
    let history: HistoryModel
    /// Fetch, pull and push: the one under way and what it asks of the user.
    let remotes = RemoteOperations()

    var selection: SidebarItem? = .history
    var selectedStash: OID?
    var workingCopy = WorkingCopyState()
    var error: PresentedError?
    /// The branching sheet on screen: merge, rename, tag, reset, delete.
    var branchingSheet: BranchingSheet?

    private(set) var snapshot: RepositorySnapshot?
    private(set) var refLabels: [OID: [RefLabel]] = [:]
    /// Counts refreshes, so views showing working copy content know to reload.
    private(set) var revision = 0
    /// Twig's own activity and the changes on disk waiting for a refresh.
    let diskChanges = DiskChanges()
    /// Sheets, confirmations and focus the menu bar asks views for.
    let viewRequests = ViewRequests()

    private let access: RepositoryAccess

    nonisolated var id: UUID { bookmark.id }
    var name: String { bookmark.name }

    init(bookmark: RepositoryBookmark, access: RepositoryAccess) throws {
        self.bookmark = bookmark
        self.access = access
        repository = try Repository(at: access.url)
        history = HistoryModel(repository: repository)
    }

    /// Reads the repository again and updates whatever changed.
    func refresh() async {
        diskChanges.refreshBegan()
        defer { diskChanges.refreshEnded() }
        do {
            let snapshot = try await repository.snapshot()
            workingCopy.entries = try await repository.status()
            workingCopy.identity = await repository.identity()
            if let selected = workingCopy.selection, !workingCopy.entries.contains(where: { $0.path == selected }) {
                workingCopy.selection = nil
            }
            if snapshot != self.snapshot {
                self.snapshot = snapshot
                refLabels = Self.labels(in: snapshot)
                await history.reload()
            }
            revision += 1
        } catch {
            self.error = PresentedError(error)
        }
    }

    /// Runs an operation on the repository, shows its error if it fails, and
    /// refreshes either way.
    func perform(_ operation: (Repository) async throws -> Void) async {
        diskChanges.operationBegan()
        do {
            try await operation(repository)
        } catch {
            self.error = PresentedError(error)
        }
        diskChanges.operationEnded()
        await refresh()
    }

    // MARK: Working copy

    /// Stages a file's changes, or unstages them if all of them are staged.
    func toggleStaging(of entry: StatusEntry) async {
        await perform { repository in
            if entry.unstaged == nil {
                try await repository.unstage([entry.path])
            } else {
                try await repository.stage([entry.path])
            }
        }
    }

    func stageAll() async {
        let paths = workingCopy.entries.filter { $0.unstaged != nil }.map(\.path)
        await perform { try await $0.stage(paths) }
    }

    func unstageAll() async {
        let paths = workingCopy.entries.filter { $0.staged != nil }.map(\.path)
        await perform { try await $0.unstage(paths) }
    }

    func commit() async {
        let message = [workingCopy.subject, workingCopy.details]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        do {
            try await repository.commit(message: message)
            workingCopy.subject = ""
            workingCopy.details = ""
        } catch {
            self.error = PresentedError(error)
        }
        await refresh()
    }

    // MARK: Reference labels

    private static func labels(in snapshot: RepositorySnapshot) -> [OID: [RefLabel]] {
        var labels: [OID: [RefLabel]] = [:]
        if let target = snapshot.head.target {
            labels[target, default: []].append(RefLabel(name: "HEAD", kind: .head))
        }
        for branch in snapshot.branches {
            labels[branch.target, default: []].append(RefLabel(name: branch.name, kind: .branch))
        }
        for tag in snapshot.tags {
            labels[tag.target, default: []].append(RefLabel(name: tag.name, kind: .tag))
        }
        for branch in snapshot.remotes.flatMap(\.branches) {
            labels[branch.target, default: []].append(RefLabel(name: branch.name, kind: .remote))
        }
        return labels
    }
}
