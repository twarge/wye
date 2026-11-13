import Foundation
import GitKit
import Observation

/// What the sidebar can select. Codable, for a window to reopen to it.
enum SidebarItem: Hashable, Codable {
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

    /// The history this item lists, for the items that list one. A branch
    /// or tag lists the full history, with the commit it points at selected
    /// there.
    var historyScope: HistoryScope? {
        switch self {
        case .history, .branch, .remoteBranch, .tag: .allReferences
        case .workingCopy, .stashes, .reflog, .submodule, .worktree, .pullRequests: nil
        }
    }

    /// Whether this is a branch, remote branch or tag, which the history
    /// shows as the commit it points at.
    var isReference: Bool {
        switch self {
        case .branch, .remoteBranch, .tag: true
        default: false
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

    var selection: SidebarItem? = .history {
        didSet {
            // Selecting a branch or tag again, from Quick Open or a link,
            // goes back to its commit too.
            referenceToReveal = selection?.isReference == true ? selection : nil
            // At once, where the full history is on screen already, so Back
            // and Forward see one step; `revealSelectedReference()` scrolls to it.
            if let commit = commitToReveal, history.scope == .allReferences {
                history.selection = commit
            }
        }
    }
    /// The branch or tag just selected in the sidebar, until the history has
    /// selected the commit it points at. See `revealSelectedReference()`.
    var referenceToReveal: SidebarItem?
    /// The commit a reopened window had selected, until the history is on
    /// screen to select it in. See `restoreSelectedCommit()`.
    var commitToRestore: OID?
    /// What a reopened window's sidebar selected, until the first snapshot
    /// says whether it is still there. See `restore(_:)`.
    @ObservationIgnored var restoredSelection: SidebarItem?
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
    /// What a window opens with, being read and shown. See `beginLoading()`.
    @ObservationIgnored private var opening: Task<Void, Never>?

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

    /// Begins reading what a window shows first, before the window is on
    /// screen: the references and the top of the history, together and off
    /// the main thread. The window then lays itself out once with all of
    /// it, where reading each as the window asks has it lay out again for
    /// the sidebar, the rows and the toolbar in turn. The working copy, and
    /// whatever else takes looking through files, follows in `refresh()`.
    func beginLoading() {
        guard opening == nil, snapshot == nil else { return }
        let request = history.beginReload()
        // Detached, to start now: the main thread is about to build the window.
        let reading = Task.detached(priority: .userInitiated) { [repository] in
            try? await repository.read { repository in
                // A submodule's own changes wait for `refresh()`: finding
                // them means looking through its whole working tree.
                (try repository.snapshot(scanningSubmodules: false), request.read(from: repository))
            }
        }
        opening = Task {
            // Unreadable: `refresh()` says why.
            guard let (snapshot, top) = await reading.value else { return }
            take(snapshot)
            if history.finishReload(request, with: top) {
                Task { await history.countCommits(for: request) }
            }
        }
    }

    /// Waits until what `beginLoading()` began to read is shown. Returns at
    /// once when nothing is being read.
    func finishLoading() async {
        guard let opening else { return }
        await opening.value
        self.opening = nil
    }

    /// Reads the repository again and updates whatever changed.
    func refresh() async {
        diskChanges.refreshBegan()
        defer { diskChanges.refreshEnded() }
        // First what an opening window began to read.
        await finishLoading()
        do {
            // In one turn, so the window shows them together.
            let (snapshot, entries, identity) = try await repository.read { repository in
                (try repository.snapshot(), try repository.status(), repository.identity())
            }
            workingCopy.entries = entries
            workingCopy.identity = identity
            updateCommitSigning()
            if let selected = workingCopy.selection, !entries.contains(where: { $0.path == selected }) {
                workingCopy.selection = nil
            }
            if take(snapshot) {
                await history.reload()
            }
            checkRestoredSelection()
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

    /// Takes a snapshot just read. Returns whether the history lists other
    /// commits for it, and is to be read again: not for a stash, a
    /// submodule's changes or anything else that moves no reference.
    @discardableResult
    private func take(_ snapshot: RepositorySnapshot) -> Bool {
        guard snapshot != self.snapshot else { return false }
        let listsOtherCommits = snapshot.historySource != self.snapshot?.historySource
        self.snapshot = snapshot
        // Not set when the same: every row of the history reads them.
        let labels = RefLabel.labels(in: snapshot)
        if labels != refLabels { refLabels = labels }
        return listsOtherCommits
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
