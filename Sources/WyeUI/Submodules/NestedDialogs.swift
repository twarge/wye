import GitKit
import SwiftUI

extension View {
    /// The sheets and questions of submodule and worktree actions, and the
    /// opening of one as a repository of its own.
    func nestedDialogs(_ model: RepositoryModel) -> some View {
        modifier(NestedDialogs(model: model))
    }
}

private struct NestedDialogs: ViewModifier {
    @Bindable var model: RepositoryModel

    @Environment(RepositoryLibrary.self) private var library
    @Environment(WindowActions.self) private var actions
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        @Bindable var nested = model.nested
        content
            .sheet(item: $nested.sheet) { sheet in
                switch sheet {
                case .addSubmodule:
                    AddSubmoduleSheet(model: model)
                case .checkOutSubmodule(let name):
                    CheckOutSubmoduleSheet(model: model, name: name)
                case .moveSubmodule(let name):
                    MoveSubmoduleSheet(model: model, name: name)
                case .changeSubmoduleURL(let name):
                    ChangeSubmoduleURLSheet(model: model, name: name)
                case .removeSubmodule(let name):
                    RemoveSubmoduleSheet(model: model, name: name)
                case .addWorktree(let target):
                    AddWorktreeSheet(model: model, initialTarget: target)
                case .lockWorktree(let name):
                    LockWorktreeSheet(model: model, name: name)
                case .moveWorktree(let name):
                    MoveWorktreeSheet(model: model, name: name)
                case .removeWorktree(let name):
                    RemoveWorktreeSheet(model: model, name: name)
                }
            }
            .confirmationDialog(
                updateTitle,
                isPresented: Binding { nested.pendingUpdate != nil } set: { if !$0 { nested.pendingUpdate = nil } },
                titleVisibility: .visible,
                presenting: nested.pendingUpdate
            ) { names in
                Button("Update") {
                    Task { await model.updateSubmodules(names) }
                }
                Button("Not Now", role: .cancel) {}
            } message: { _ in
                Text("The commits this repository records for them changed. Updating checks each out at its recorded commit. "
                     + "Change when this happens in Settings.")
            }
            .onChange(of: nested.opening) {
                if let opening = nested.opening {
                    nested.opening = nil
                    open(opening)
                }
            }
            .background {
                // On its own view, so it does not take the place of the
                // window's other file dialogs.
                Color.clear
                    .fileImporter(
                        isPresented: Binding { nested.folderToGrant != nil } set: { if !$0 { nested.folderToGrant = nil } },
                        allowedContentTypes: [.folder]
                    ) { result in
                        grant(result)
                    }
                    .fileDialogDefaultDirectory(nested.folderToGrant.map {
                        URL(filePath: $0.path, directoryHint: .isDirectory).deletingLastPathComponent()
                    })
                    .fileDialogMessage(Text(grantMessage))
                    .fileDialogConfirmationLabel(Text("Open Worktree"))
            }
    }

    private var updateTitle: String {
        let names = model.nested.pendingUpdate ?? []
        return names.count == 1 ? "Update the Submodule “\(names[0])”?" : "Update \(names.count) Submodules?"
    }

    private var grantMessage: String {
        guard let worktree = model.nested.folderToGrant else { return "" }
        return "Wye needs your permission to open the worktree at \(worktree.path). Choose that folder."
    }

    // MARK: Opening

    private func open(_ opening: NestedOpening) {
        switch opening {
        case .submodule(let name):
            guard let submodule = model.submodule(named: name) else { return }
            guard submodule.status.isCloned else {
                model.error = PresentedError(SubmoduleError.notCloned(submodule.path))
                return
            }
            let url = model.repository.url.appending(path: submodule.path, directoryHint: .isDirectory)
            // Inside this repository's folder, so always reachable.
            if let bookmark = library.bookmark(forRepositoryAt: url, from: model.bookmark, linkedWorktree: false) {
                show(bookmark)
            }
        case .worktree(let name):
            guard let worktree = model.worktree(named: name), !worktree.isCurrent else { return }
            guard !worktree.isMissing else {
                model.error = PresentedError(WorktreeError.notFound(worktree.displayName))
                return
            }
            let url = URL(filePath: worktree.path, directoryHint: .isDirectory)
            if let bookmark = library.bookmark(forRepositoryAt: url, from: model.bookmark, linkedWorktree: !worktree.isMain) {
                show(bookmark)
            } else {
                // Somewhere Wye was never given: the user grants it.
                model.nested.folderToGrant = worktree
            }
        }
    }

    private func grant(_ result: Result<URL, any Error>) {
        guard let worktree = model.nested.folderToGrant else { return }
        model.nested.folderToGrant = nil
        do {
            let picked = try result.get()
            let bookmark = try library.addGrantedWorktree(
                picked, expected: URL(filePath: worktree.path, directoryHint: .isDirectory),
                main: worktree.isMain ? nil : model.bookmark
            )
            show(bookmark)
        } catch {
            model.error = PresentedError(error)
        }
    }

    private func show(_ bookmark: RepositoryBookmark) {
        if Platform.opensNestedRepositoriesInNewTab {
            // The new window picks the repository up as it appears.
            library.openInNextWindow = bookmark.id
            Platform.openAsTab { openWindow(id: WyeScene.windowID) }
        } else {
            actions.open(bookmark)
        }
    }
}
