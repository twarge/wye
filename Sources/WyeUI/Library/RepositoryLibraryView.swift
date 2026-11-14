import SwiftUI
import UniformTypeIdentifiers

/// The list of repositories, shown when a window has none open: each with
/// what wants looking at in it, so there is no second list to turn to.
struct RepositoryLibraryView: View {
    @Environment(RepositoryLibrary.self) private var library
    @Environment(WindowActions.self) private var actions
    @Environment(\.openWindow) private var openWindow
    var open: (RepositoryBookmark) -> Void

    @State private var query = ""
    @AppStorage("repositoryListOrder") private var order = RepositoryListOrder.name
    @State private var naming: GroupNaming?
    @State private var groupName = ""
    @State private var isChoosingFolderToWatch = false

    var body: some View {
        NavigationStack {
            RepositoryList(query: query, order: order, open: open) { naming in
                groupName = if case .rename(let group) = naming { group.name } else { "" }
                self.naming = naming
            }
            .overlay {
                if library.listedBookmarks.isEmpty, library.folders.isEmpty {
                    ContentUnavailableView {
                        Label("No Repositories", systemImage: "arrow.triangle.branch")
                    } description: {
                        #if os(macOS)
                        Text("Add a folder that holds a git repository, or clone one, to browse its history and commit changes.")
                        #else
                        Text("Clone a repository, or start a new one, to browse its history and commit changes.")
                        #endif
                    } actions: {
                        #if os(macOS)
                        // One above the other, each as wide as the widest.
                        VStack(spacing: 8) {
                            Button { actions.isAddingRepository = true } label: {
                                Text("Add Repository…").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button { isChoosingFolderToWatch = true } label: {
                                Text("Watch a Folder of Repositories…").frame(maxWidth: .infinity)
                            }
                            Button { actions.isCloning = true } label: {
                                Text("Clone Repository…").frame(maxWidth: .infinity)
                            }
                            Button { actions.isCreatingRepository = true } label: {
                                Text("New Repository…").frame(maxWidth: .infinity)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        #else
                        // Cloning is how a repository gets onto the device,
                        // so it comes first. A folder to add or watch is one
                        // another app keeps, which few have: those stay in
                        // the toolbar. Each button is large enough to tap.
                        VStack(spacing: 12) {
                            Button { actions.isCloning = true } label: {
                                Text("Clone Repository…").frame(maxWidth: .infinity)
                            }
                            .emptyStateButton(prominent: true)
                            Button { actions.isCreatingRepository = true } label: {
                                Text("New Repository…").frame(maxWidth: .infinity)
                            }
                            .emptyStateButton()
                        }
                        .frame(maxWidth: 300)
                        #endif
                    }
                }
            }
            // Inside the stack, so the strip sits under its bar, not over it.
            .noticeStrip(actions.notices)
            .searchable(text: $query, prompt: "Repository, branch, file, commit or pull request")
            .navigationTitle("Repositories")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Pull All", systemImage: "arrow.down.to.line") { actions.isPullingAll = true }
                        .help("Pull every repository and report what did not work")
                        .disabled(library.listedBookmarks.isEmpty)
                }
                // The menu bar gives these their shortcuts, ⌘O and ⌥⌘O.
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Repository", systemImage: "plus") { actions.isAddingRepository = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clone Repository", systemImage: "square.and.arrow.down") { actions.isCloning = true }
                        .help("Clone a repository from a URL")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Repository", systemImage: "plus.rectangle.on.folder") { actions.isCreatingRepository = true }
                        .help("Create a new, empty repository")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu("Watched Folders", systemImage: "eye") {
                        ForEach(library.folders) { folder in
                            Menu(library.path(of: folder) ?? folder.name) {
                                Button("Stop Watching", systemImage: "eye.slash", role: .destructive) {
                                    library.stopWatching(folder)
                                }
                            }
                        }
                        Button("Watch Folder…", systemImage: "plus") { isChoosingFolderToWatch = true }
                    }
                    .help("List every repository in a folder, as they come and go")
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
                    Button("Activity", systemImage: "list.bullet.clipboard") {
                        if Platform.hasAuxiliaryWindows {
                            openWindow(id: WyeScene.activityWindowID)
                        } else {
                            actions.isShowingActivity = true
                        }
                    }
                    .badge(ActivityLog.shared.unseenFailures)
                    .help("Every operation Wye has run this session")
                }
                ToolbarItem(placement: .secondaryAction) {
                    SettingsButton { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
        .background {
            // On its own view: a view takes one file importer, and the
            // window already has the one that adds a repository.
            Color.clear
                .fileImporter(isPresented: $isChoosingFolderToWatch, allowedContentTypes: [.folder]) { result in
                    do {
                        try library.watch(try result.get())
                    } catch {
                        actions.notices.post(error, during: "Watch Folder")
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
