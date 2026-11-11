import GitKit
import SwiftUI

/// Asks for a new submodule's URL, path and branch.
struct AddSubmoduleSheet: View {
    var model: RepositoryModel

    @State private var url = ""
    @State private var path = ""
    /// Whether the user typed a path, which then stops following the URL.
    @State private var hasEditedPath = false
    @State private var branch = ""

    var body: some View {
        BranchingSheetForm(title: "Add Submodule", confirmTitle: "Add", canConfirm: canAdd, confirm: add) {
            Section {
                TextField("URL", text: $url, prompt: Text("https://example.com/owner/library.git or ../library.git"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                    .onChange(of: url) {
                        if !hasEditedPath { path = CloneSheet.suggestedName(for: url) }
                    }
                TextField("Path", text: Binding { path } set: {
                    path = $0
                    hasEditedPath = true
                })
                .autocorrectionDisabled()
                .noAutocapitalization()
                TextField("Branch", text: $branch, prompt: Text("The remote’s default"))
                    .autocorrectionDisabled()
                    .noAutocapitalization()
            } footer: {
                Text("Twig clones it into the path, then stages .gitmodules and the submodule for you to commit. "
                     + "A URL starting with ../ is relative to this repository’s remote.")
            }
        }
    }

    private var canAdd: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty && !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        let url = url, path = path, branch = branch
        Task { await model.addSubmodule(url: url, path: path, branch: branch.isEmpty ? nil : branch) }
    }
}

/// Asks which revision to check out inside a submodule.
struct CheckOutSubmoduleSheet: View {
    var model: RepositoryModel
    var name: String

    @State private var revision = ""
    @State private var branches: [String] = []
    @State private var tags: [String] = []

    var body: some View {
        BranchingSheetForm(
            title: "Check Out Revision", confirmTitle: "Check Out",
            canConfirm: !revision.trimmingCharacters(in: .whitespaces).isEmpty, confirm: checkOut
        ) {
            Section {
                LabeledContent("Submodule", value: model.submodule(named: name)?.path ?? name)
                TextField("Revision", text: $revision, prompt: Text("A branch, tag or commit"))
                    .font(.code)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                if !branches.isEmpty || !tags.isEmpty {
                    Menu("Choose") {
                        Section("Branches") {
                            ForEach(branches, id: \.self) { name in Button(name) { revision = name } }
                        }
                        Section("Tags") {
                            ForEach(tags, id: \.self) { name in Button(name) { revision = name } }
                        }
                    }
                }
            } footer: {
                Text("A local branch is checked out as itself; anything else leaves the submodule’s HEAD detached. "
                     + "This repository then shows the submodule as changed: stage it to record the new commit.")
            }
        }
        .task {
            guard let inner = try? await model.repository.openSubmodule(name),
                  let snapshot = try? await inner.snapshot() else { return }
            branches = snapshot.branches.map(\.name) + snapshot.remotes.flatMap(\.branches).map(\.name)
                .filter { !$0.hasSuffix("/HEAD") }
            tags = snapshot.tags.map(\.name)
        }
    }

    private func checkOut() {
        let revision = revision
        let name = name
        Task { await model.checkOutSubmodule(name, revision: revision) }
    }
}

/// Asks for a submodule's new path.
struct MoveSubmoduleSheet: View {
    var model: RepositoryModel
    var name: String

    @Environment(RepositoryLibrary.self) private var library
    @State private var path = ""

    var body: some View {
        let old = model.submodule(named: name)?.path ?? name
        BranchingSheetForm(
            title: "Move Submodule", confirmTitle: "Move",
            canConfirm: !path.trimmingCharacters(in: .whitespaces).isEmpty && path != old, confirm: move
        ) {
            Section {
                TextField("Path", text: $path)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
            } footer: {
                Text("Moves the submodule’s folder and stages the change to .gitmodules and to the submodule’s entry. "
                     + "Its name, “\(name)”, stays.")
            }
        }
        .onAppear { path = old }
    }

    private func move() {
        let path = path, name = name, library = library
        Task { await model.moveSubmodule(name, to: path, library: library) }
    }
}

/// Asks for a submodule's new URL.
struct ChangeSubmoduleURLSheet: View {
    var model: RepositoryModel
    var name: String

    @State private var url = ""

    var body: some View {
        BranchingSheetForm(
            title: "Change Submodule URL", confirmTitle: "Change",
            canConfirm: !url.trimmingCharacters(in: .whitespaces).isEmpty, confirm: change
        ) {
            Section {
                TextField("URL", text: $url)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
            } footer: {
                Text("Changes the URL in .gitmodules, staged, and in this repository’s configuration and the submodule’s remote.")
            }
        }
        .onAppear { url = model.submodule(named: name)?.url ?? "" }
    }

    private func change() {
        let url = url, name = name
        Task { await model.changeSubmoduleURL(name, to: url) }
    }
}

/// Confirms removing a submodule, saying what goes with it.
struct RemoveSubmoduleSheet: View {
    var model: RepositoryModel
    var name: String

    @Environment(RepositoryLibrary.self) private var library

    var body: some View {
        let submodule = model.submodule(named: name)
        BranchingSheetForm(title: "Remove Submodule", confirmTitle: "Remove", isDestructive: true, confirm: remove) {
            Section {
                LabeledContent("Submodule", value: submodule?.path ?? name)
            } footer: {
                Text(explanation(submodule))
            }
        }
    }

    private func explanation(_ submodule: Submodule?) -> String {
        var text = "The submodule’s folder and its repository in .git/modules are deleted, and its entries in .gitmodules "
            + "and the configuration removed. The removal is staged, to commit. "
        if let changes = submodule?.changes.subtracting(.newCommits).summary {
            text += "It has \(changes), which are lost. "
        }
        text += "Commits that only its clone here has, not pushed anywhere, are lost too. This cannot be undone."
        return text
    }

    private func remove() {
        let name = name, library = library
        Task { await model.removeSubmodule(name, library: library) }
    }
}
