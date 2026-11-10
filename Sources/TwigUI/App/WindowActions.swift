import GitKit
import SwiftUI

/// What the menu bar can ask of one window apart from its repository: the
/// sheets for adding and cloning repositories, quick open, and closing the
/// repository. A window publishes it as a focused value so the commands act
/// on the front window.
@MainActor
@Observable
final class WindowActions {
    var isAddingRepository = false
    var isCloning = false
    /// Quick open on screen, and what it is choosing for.
    var quickOpen: QuickOpenPurpose?
    var error: PresentedError?

    /// Set by the window: open a repository in it, and go back to the list.
    var open: (RepositoryBookmark) -> Void = { _ in }
    var close: () -> Void = {}

    /// What quick open chose, acted on once its sheet is gone, so a sheet it
    /// leads to does not try to appear while the first is leaving.
    fileprivate var chosen: (item: QuickOpenItem, purpose: QuickOpenPurpose)?

    /// Adds the picked folders, opening the repository when there is just
    /// one, unless told not to. Returns the repositories added before any
    /// folder failed.
    @discardableResult
    func add(_ urls: [URL], to library: RepositoryLibrary, opening: Bool = true) -> [RepositoryBookmark] {
        var added: [RepositoryBookmark] = []
        do {
            // Only folders: a dragged row of the list itself is not one to add.
            for url in urls where url.isFileURL {
                added.append(try library.add(url))
            }
        } catch {
            self.error = PresentedError(error)
        }
        if opening, urls.count == 1, let bookmark = added.first {
            open(bookmark)
        }
        return added
    }
}

extension View {
    /// Publishes a window's actions to the menu bar and shows the sheets
    /// they ask for. `model` is the repository the window shows, if any.
    func windowActions(_ actions: WindowActions, model: RepositoryModel?) -> some View {
        modifier(WindowActionsPresenter(actions: actions, model: model))
    }
}

private struct WindowActionsPresenter: ViewModifier {
    @Bindable var actions: WindowActions
    var model: RepositoryModel?

    @Environment(RepositoryLibrary.self) private var library

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(actions)
            .environment(actions)
            .sheet(isPresented: $actions.isCloning) {
                CloneSheet { actions.open($0) }
            }
            .fileImporter(isPresented: $actions.isAddingRepository, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): actions.add([url], to: library)
                case .failure(let failure): actions.error = PresentedError(failure)
                }
            }
            .sheet(item: $actions.quickOpen, onDismiss: goToChosen) { purpose in
                QuickOpenView(
                    purpose: purpose,
                    currentBranch: model?.headBranchName,
                    items: QuickOpenItem.items(
                        for: purpose, snapshot: model?.snapshot, repositories: library.bookmarks,
                        currentRepository: model?.id
                    )
                ) { item in
                    actions.chosen = (item, purpose)
                    actions.quickOpen = nil
                }
            }
            .background {
                // On its own view, so it does not take the place of the window's alert.
                Color.clear.alert(for: $actions.error)
            }
    }

    private func goToChosen() {
        guard let (item, purpose) = actions.chosen else { return }
        actions.chosen = nil
        switch (item.target, purpose) {
        case (.repository(let bookmark), _):
            if bookmark.id != model?.id { actions.open(bookmark) }
        case (.branch(let name), .merge), (.remoteBranch(let name), .merge), (.tag(let name), .merge):
            model?.present(.merge(name))
        case (.branch(let name), .rebase), (.remoteBranch(let name), .rebase):
            model?.present(.rebase(onto: name))
        case (.branch(let name), _):
            model?.selection = .branch(name)
        case (.remoteBranch(let name), _):
            model?.selection = .remoteBranch(name)
        case (.tag(let name), _):
            model?.selection = .tag(name)
        }
    }
}
