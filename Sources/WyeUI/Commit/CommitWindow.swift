import GitKit
import SwiftUI

/// What a commit window shows: a commit of a repository in the library, by
/// their names, so the window comes back when the app opens again.
struct CommitWindowTarget: Codable, Hashable {
    /// The repository's bookmark.
    var repository: UUID
    /// The commit's full hash.
    var commit: String

    init(repository: UUID, commit: OID) {
        self.repository = repository
        self.commit = commit.hex
    }
}

extension WyeScene {
    /// Names the commit windows, which a commit's double-click opens.
    static let commitWindowID = "commit"
}

/// A commit in a window of its own: what it changed, and its files beside
/// the file chosen among them. It shares the repository with the window
/// that has it open, so both follow the same changes; opened on its own,
/// as when the app comes back, it opens the repository itself.
struct CommitWindow: View {
    var target: CommitWindowTarget

    @Environment(RepositoryLibrary.self) private var library
    @State private var model: RepositoryModel?
    /// The commit shown, which a parent's hash in the header moves to.
    @State private var commitID: OID?
    @State private var failure: String?

    var body: some View {
        Group {
            if let model, let commitID {
                CommitDetailView(model: model, commitID: commitID, titlesWindow: true) { self.commitID = $0 }
                    // Its own notices, as the repository's window may be closed
                    // or behind it.
                    .sheetNotices(model)
            } else if let failure {
                ContentUnavailableView("Can’t Open the Commit", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .task(id: target) {
            await open()
        }
    }

    private func open() async {
        guard let id = OID(hex: target.commit) else {
            failure = String(localized: "The commit’s name is not a hash.")
            return
        }
        commitID = id
        if let shared = OpenRepositories.models(for: target.repository).first {
            model = shared
            return
        }
        guard let bookmark = library.bookmarks.first(where: { $0.id == target.repository }) else {
            failure = String(localized: "The repository is no longer in the library.")
            return
        }
        do {
            let opened = try RepositoryModel(bookmark: bookmark, access: library.access(to: bookmark))
            model = opened
            await opened.refresh()
        } catch {
            failure = error.localizedDescription
        }
    }
}

extension View {
    /// Opens a commit in a window of its own, where windows can be opened.
    func opensCommitWindows(_ model: RepositoryModel) -> some View {
        modifier(CommitWindowOpener(model: model))
    }
}

/// Supplies `openCommitWindow` to what is inside.
private struct CommitWindowOpener: ViewModifier {
    var model: RepositoryModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    func body(content: Content) -> some View {
        let repository = model.id
        content.environment(\.openCommitWindow, supportsMultipleWindows ? OpenCommitWindowAction { commit in
            openWindow(id: WyeScene.commitWindowID, value: CommitWindowTarget(repository: repository, commit: commit))
        } : nil)
    }
}

extension EnvironmentValues {
    /// Opens a commit in a window of its own; `nil` where there is only
    /// the one window, as on iPhone.
    @Entry var openCommitWindow: OpenCommitWindowAction?
}

/// Opens a commit in a window of its own; call it like a function.
struct OpenCommitWindowAction {
    let handler: @MainActor (OID) -> Void

    @MainActor
    func callAsFunction(_ commit: OID) {
        handler(commit)
    }
}
