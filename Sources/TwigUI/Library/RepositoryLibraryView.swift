import SwiftUI
import UniformTypeIdentifiers

/// The list of repositories, shown when a window has none open.
struct RepositoryLibraryView: View {
    @Environment(RepositoryLibrary.self) private var library
    @Environment(WindowActions.self) private var actions
    var open: (RepositoryBookmark) -> Void

    @State private var query = ""
    @AppStorage("repositoryListOrder") private var order = RepositoryListOrder.name
    @State private var naming: GroupNaming?
    @State private var groupName = ""

    var body: some View {
        NavigationStack {
            RepositoryList(query: query, order: order, open: open) { naming in
                groupName = if case .rename(let group) = naming { group.name } else { "" }
                self.naming = naming
            }
            .overlay {
                if library.bookmarks.isEmpty {
                    ContentUnavailableView {
                        Label("No Repositories", systemImage: "arrow.triangle.branch")
                    } description: {
                        Text("Add a folder that holds a git repository, or clone one, to browse its history and commit changes.")
                    } actions: {
                        Button("Add Repository…") { actions.isAddingRepository = true }
                            .buttonStyle(.borderedProminent)
                        Button("Clone Repository…") { actions.isCloning = true }
                    }
                }
            }
            .searchable(text: $query, prompt: "Name, folder or branch")
            .navigationTitle("Repositories")
            .toolbar {
                // The menu bar gives these their shortcuts, ⌘O and ⇧⌘O.
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Repository", systemImage: "plus") { actions.isAddingRepository = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clone Repository", systemImage: "square.and.arrow.down") { actions.isCloning = true }
                        .help("Clone a repository from a URL")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("New Group", systemImage: "folder.badge.plus") { naming = .new(moving: []) }
                        .help("Make a group to sort repositories into")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu("Sort By", systemImage: "arrow.up.arrow.down") {
                        Picker("Sort By", selection: $order) {
                            ForEach(RepositoryListOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    SettingsButton { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
        .alert(naming.map(alertTitle) ?? "", isPresented: Binding { naming != nil } set: { if !$0 { naming = nil } }) {
            TextField("Name", text: $groupName)
            Button("Cancel", role: .cancel) {}
            Button(naming.map(confirmTitle) ?? "OK") { saveGroup() }
                .disabled(trimmedGroupName.isEmpty)
        }
    }

    private var trimmedGroupName: String {
        groupName.trimmingCharacters(in: .whitespaces)
    }

    private func alertTitle(_ naming: GroupNaming) -> String {
        switch naming {
        case .new: "New Group"
        case .rename: "Rename Group"
        }
    }

    private func confirmTitle(_ naming: GroupNaming) -> String {
        switch naming {
        case .new: "Create"
        case .rename: "Rename"
        }
    }

    private func saveGroup() {
        let name = trimmedGroupName
        guard !name.isEmpty, let naming else { return }
        switch naming {
        case .new(let moving):
            let group = library.createGroup(named: name)
            if !moving.isEmpty {
                library.move(moving, to: group.id)
            }
        case .rename(let group):
            library.renameGroup(group, to: name)
        }
        self.naming = nil
    }
}
