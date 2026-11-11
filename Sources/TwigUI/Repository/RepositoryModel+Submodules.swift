import Foundation
import GitKit
import Observation

/// A sheet a submodule or worktree action asks for. Menus set
/// `NestedRequests.sheet`; the repository window shows it.
enum NestedSheet: Identifiable, Hashable {
    case addSubmodule
    /// A submodule, by name.
    case checkOutSubmodule(String)
    case moveSubmodule(String)
    case changeSubmoduleURL(String)
    case removeSubmodule(String)
    /// A new worktree, starting from this target when one is given.
    case addWorktree(WorktreeTarget?)
    /// A worktree, by name.
    case lockWorktree(String)
    case moveWorktree(String)
    case removeWorktree(String)

    var id: Self { self }
}

/// A submodule or worktree to open as a repository of its own.
enum NestedOpening: Hashable {
    case submodule(String)
    case worktree(String)
}

/// What submodule and worktree actions ask of the window: sheets, the
/// question after an operation moved submodules, a folder to grant.
@MainActor
@Observable
final class NestedRequests {
    var sheet: NestedSheet?
    /// Submodules whose recorded commit an operation changed, while the
    /// window asks whether to update them.
    var pendingUpdate: [String]?
    /// A submodule or worktree to open, taken by the window, which knows
    /// the library and how to open windows.
    var opening: NestedOpening?
    /// A worktree whose folder Twig has no access to, while the window asks
    /// the user to choose it.
    var folderToGrant: Worktree?
}

extension RepositoryModel {
    func submodule(named name: String) -> Submodule? {
        snapshot?.submodules.first { $0.name == name }
    }

    var hasSubmodules: Bool {
        snapshot?.submodules.isEmpty == false
    }

    // MARK: Network

    /// Updates the named submodules, or all of them: initializes and clones
    /// those that need it and checks each out at the recorded commit, going
    /// on into their own submodules.
    func updateSubmodules(_ names: [String]? = nil, fetch: Bool = false) async {
        let title = names?.count == 1 ? "Updating “\(names![0])”" : "Updating Submodules"
        await runRemote(title) { repository, transfer, _ in
            try await repository.updateSubmodules(
                names, initialize: true, recursive: true, fetch: fetch,
                credentials: CredentialStore.shared, transfer: transfer
            )
        }
    }

    func fetchSubmodules(_ names: [String]? = nil) async {
        await runRemote("Fetching Submodules") { repository, transfer, _ in
            try await repository.fetchSubmodules(names, credentials: CredentialStore.shared, transfer: transfer)
        }
    }

    /// Clones a new submodule and stages it.
    func addSubmodule(url: String, path: String, branch: String?) async {
        await runRemote("Adding Submodule") { repository, transfer, _ in
            let name = try await repository.addSubmodule(
                url: url, path: path, branch: branch, credentials: CredentialStore.shared, transfer: transfer
            )
            self.selection = .submodule(name)
        }
    }

    // MARK: Local

    func initializeSubmodules(_ names: [String]? = nil) async {
        await perform { try await $0.initializeSubmodules(names) }
    }

    func synchronizeSubmodules(_ names: [String]? = nil) async {
        await perform { try await $0.synchronizeSubmodules(names) }
    }

    /// Checks out a revision inside a submodule, which the working copy then
    /// shows as a change to stage.
    func checkOutSubmodule(_ name: String, revision: String) async {
        await perform { try await $0.checkOutSubmodule(name, revision: revision) }
    }

    func changeSubmoduleURL(_ name: String, to url: String) async {
        await perform { try await $0.setSubmoduleURL(name, to: url) }
    }

    /// Moves a submodule, and its entry in the library if it was opened.
    func moveSubmodule(_ name: String, to path: String, library: RepositoryLibrary) async {
        guard let old = submodule(named: name) else { return }
        let listed = library.bookmark(at: repository.url.appending(path: old.path))
        await perform { repository in
            try await repository.moveSubmodule(name, to: path)
            if let listed {
                library.relocate(listed, to: repository.url.appending(path: path), parent: self.bookmark)
            }
        }
    }

    /// Removes a submodule completely, and forgets it in the library.
    func removeSubmodule(_ name: String, library: RepositoryLibrary) async {
        guard let old = submodule(named: name) else { return }
        let listed = library.bookmark(at: repository.url.appending(path: old.path))
        await perform { repository in
            try await repository.removeSubmodule(name, force: true)
            if let listed { library.remove(listed) }
            if self.selection == .submodule(name) {
                self.selection = .history
            }
        }
    }

    // MARK: Following recorded commits

    /// The commit the superproject records for each submodule, read before
    /// an operation so that what it changed can be told afterwards.
    func recordedSubmoduleCommits() -> [String: OID?]? {
        guard let submodules = snapshot?.submodules, !submodules.isEmpty else { return snapshot == nil ? nil : [:] }
        return Dictionary(submodules.map { ($0.name, $0.recordedID) }, uniquingKeysWith: { first, _ in first })
    }

    /// After a checkout, pull, merge, reset or the like: updates the
    /// submodules whose recorded commit it changed, or asks first, as the
    /// setting says. The one place those operations hand over to submodules.
    func followRecordedSubmodules(from before: [String: OID?]?) async {
        guard let before, SubmodulePreferences.autoUpdate != .off, let submodules = snapshot?.submodules else { return }
        let moved = submodules.filter { submodule in
            let recordedBefore = before[submodule.name] ?? nil
            return recordedBefore != submodule.recordedID
                && [.differentCommit, .notCloned, .notInitialized].contains(submodule.status)
        }
        guard !moved.isEmpty else { return }
        switch SubmodulePreferences.autoUpdate {
        case .always:
            await updateSubmodules(moved.map(\.name))
        case .ask:
            nested.pendingUpdate = moved.map(\.name)
        case .off:
            break
        }
    }
}

/// When submodules follow an operation that changes their recorded commit.
enum SubmoduleUpdatePolicy: String, CaseIterable, Identifiable {
    case off
    case ask
    case always

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Never"
        case .ask: "Ask"
        case .always: "Always"
        }
    }
}

enum SubmodulePreferences {
    static let autoUpdateKey = "submoduleAutoUpdate"

    static var autoUpdate: SubmoduleUpdatePolicy {
        UserDefaults.standard.string(forKey: autoUpdateKey).flatMap(SubmoduleUpdatePolicy.init(rawValue:)) ?? .ask
    }
}

extension SubmoduleState {
    var title: String {
        switch self {
        case .notInitialized: "Not Initialized"
        case .notCloned: "Not Cloned"
        case .upToDate: "Up to Date"
        case .differentCommit: "At Another Commit"
        case .modifiedContent: "Modified"
        case .missing: "Missing"
        }
    }

    var explanation: String {
        switch self {
        case .notInitialized: "Listed in .gitmodules, but not set up here. Update to initialize and clone it."
        case .notCloned: "Initialized, but not cloned yet. Update to clone it."
        case .upToDate: "Checked out at the commit this repository records."
        case .differentCommit: "Checked out at another commit than the one recorded. Stage it to record the new one, or update to go back."
        case .modifiedContent: "At the recorded commit, with uncommitted changes inside."
        case .missing: "Its folder is gone from the working copy. Update to bring it back."
        }
    }

    var systemImage: String {
        switch self {
        case .notInitialized: "circle.dashed"
        case .notCloned: "arrow.down.circle"
        case .upToDate: "checkmark.circle"
        case .differentCommit: "arrow.triangle.branch"
        case .modifiedContent: "pencil.circle"
        case .missing: "exclamationmark.triangle"
        }
    }

    /// Whether there is a repository inside to open, fetch or check out in.
    var isCloned: Bool {
        switch self {
        case .upToDate, .differentCommit, .modifiedContent: true
        case .notInitialized, .notCloned, .missing: false
        }
    }
}

extension SubmoduleChanges {
    /// "new commits, modified content", as git's status says it.
    var summary: String? {
        var parts: [String] = []
        if contains(.newCommits) { parts.append("new commits") }
        if contains(.modifiedContent) { parts.append("modified content") }
        if contains(.untrackedContent) { parts.append("untracked content") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
