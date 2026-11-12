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
    /// The pull requests (merge requests on GitLab) of the repository's hosting service.
    case pullRequests

    /// The history this item lists, for the items that list one.
    var historyScope: HistoryScope? {
        switch self {
        case .history: .allReferences
        case .branch(let name), .remoteBranch(let name), .tag(let name): .reference(name)
        case .workingCopy, .stashes, .reflog, .submodule, .worktree, .pullRequests: nil
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
    /// Remote branches at the same commit that this local branch's badge
    /// stands for too, by name (`origin/main`). See `RefLabel.labels(in:)`.
    var remotes: [String] = []

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
    /// Every selected file, when several are (`selection` is the one shown).
    var selectedPaths: Set<String> = []
    /// The author profile picked for the next commit only.
    var commitProfile: UUID?

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
    /// What went wrong and what operations left behind, for the strip at
    /// the top of the window. Nothing here stops the user working.
    let notices = NoticeCenter()
    /// The branching sheet on screen: merge, rename, tag, reset, delete.
    var branchingSheet: BranchingSheet?

    private(set) var snapshot: RepositorySnapshot?
    private(set) var refLabels: [OID: [RefLabel]] = [:]
    /// Counts refreshes, so views showing working copy content know to reload.
    private(set) var revision = 0
    /// Wye's own activity and the changes on disk waiting for a refresh.
    let diskChanges = DiskChanges()
    /// Sheets, confirmations and focus the menu bar asks views for.
    let viewRequests = ViewRequests()
    /// Interactive rebase, rebase onto and editing earlier commits.
    let rebasing = RebaseRequests()
    /// File actions waiting on a confirmation or a new name.
    let fileRequests = FileRequests()
    /// What Undo and Redo apply next.
    let undoStack: UndoStack
    /// Submodule and worktree sheets, questions and windows to open.
    let nested = NestedRequests()
    /// Pinned and archived branches, and how branches stand against the
    /// main branch.
    let interface: RepositoryInterfaceState
    /// Back and Forward, and the repository settings sheet.
    let windowState = RepositoryWindowState()
    /// Publishing, pull requests and the account a remote uses.
    let hosting = HostingState()

    private let access: RepositoryAccess
    /// What the last refresh failed with, while it keeps failing.
    @ObservationIgnored private var refreshFailure: String?

    nonisolated var id: UUID { bookmark.id }
    var name: String { bookmark.name }

    init(bookmark: RepositoryBookmark, access: RepositoryAccess) throws {
        self.bookmark = bookmark
        self.access = access
        repository = try Repository(at: access.url)
        history = HistoryModel(repository: repository)
        undoStack = UndoStack(repositoryID: bookmark.id)
        interface = RepositoryInterfaceState(repositoryID: bookmark.id)
    }

    /// Reads the repository again and updates whatever changed.
    func refresh() async {
        diskChanges.refreshBegan()
        defer { diskChanges.refreshEnded() }
        do {
            let snapshot = try await repository.snapshot()
            workingCopy.entries = try await repository.status()
            workingCopy.identity = await repository.identity()
            updateCommitSigning()
            if let selected = workingCopy.selection, !workingCopy.entries.contains(where: { $0.path == selected }) {
                workingCopy.selection = nil
            }
            if snapshot != self.snapshot {
                self.snapshot = snapshot
                refLabels = RefLabel.labels(in: snapshot)
                await history.reload()
            }
            revision += 1
            if refreshFailure != nil {
                refreshFailure = nil
                notices.resolve(operation: Self.readingTitle)
            }
        } catch {
            noteRefreshFailure(error)
        }
        // Every operation and change on disk ends here.
        FilesLocationSignal.repositoryChanged(at: repository.url)
    }

    static let readingTitle = "Read Repository"

    /// A refresh the user did not ask for failed: said once, quietly, and
    /// kept in the activity log. The folder changing again would otherwise
    /// say the same thing over and over.
    private func noteRefreshFailure(_ error: any Error) {
        let message = error.localizedDescription
        guard message != refreshFailure else { return }
        refreshFailure = message
        let entry = ActivityLog.shared.begin(Self.readingTitle, repository: name, isBackground: true)
        ActivityLog.shared.finish(entry, error: error)
        notices.post(Notice(
            .warning, title: "Couldn’t Read the Repository", message: message,
            recoveries: [.showActivity], operation: Self.readingTitle
        ))
    }

    /// Tells the user an operation failed, in the window's notices: named
    /// after the operation under way unless the caller names it.
    func report(_ error: any Error, during operation: String? = nil) {
        notices.post(error, during: operation ?? ActivityContext.operationTitle)
    }

    /// Runs an operation on the repository, says so if it fails, and
    /// refreshes either way.
    func perform(_ operation: (Repository) async throws -> Void) async {
        diskChanges.operationBegan()
        let title = ActivityContext.operationTitle
        let logged = ActivityLog.shared.begin(title ?? "Operation", repository: name)
        var failure: (any Error)?
        do {
            try await operation(repository)
            if let title { notices.resolve(operation: title) }
        } catch {
            failure = error
            report(error, during: title)
        }
        ActivityLog.shared.finish(logged, error: failure)
        diskChanges.operationEnded()
        await refresh()
    }

    // MARK: Working copy

    /// Stages a file's changes, or unstages them if all of them are staged.
    func toggleStaging(of entry: StatusEntry) async {
        await perform(entry.unstaged == nil ? .unstage : .stage) { repository in
            if entry.unstaged == nil {
                try await repository.unstage([entry.path])
            } else {
                try await repository.stage([entry.path])
            }
        }
    }

    func stageAll() async {
        let paths = workingCopy.entries.filter { $0.unstaged != nil }.map(\.path)
        await perform(.stage) { try await $0.stage(paths) }
    }

    func unstageAll() async {
        let paths = workingCopy.entries.filter { $0.staged != nil }.map(\.path)
        await perform(.unstage) { try await $0.unstage(paths) }
    }

    func commit() async {
        let message = [workingCopy.subject, workingCopy.details]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let logged = ActivityLog.shared.begin("Commit", repository: name)
        do {
            let start = await repository.beginUndoable(.commit)
            try await repository.commit(message: message, as: commitIdentity)
            undoStack.take(await repository.finishUndoable(start), for: .commit)
            workingCopy.subject = ""
            workingCopy.details = ""
            ActivityLog.shared.finish(logged, error: nil)
            notices.resolve(operation: "Commit")
        } catch {
            ActivityLog.shared.finish(logged, error: error)
            report(error, during: "Commit")
        }
        await refresh()
    }
}
