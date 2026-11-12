import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// The list of repositories, shown when a window has none open.
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
            Group {
                if actions.isReviewing {
                    ReviewView(query: query, open: open)
                } else {
                    RepositoryList(query: query, order: order, open: open) { naming in
                        groupName = if case .rename(let group) = naming { group.name } else { "" }
                        self.naming = naming
                    }
                }
            }
            .overlay {
                if library.listedBookmarks.isEmpty, library.folders.isEmpty {
                    ContentUnavailableView {
                        Label("No Repositories", systemImage: "arrow.triangle.branch")
                    } description: {
                        Text("Add a folder that holds a git repository, or clone one, to browse its history and commit changes.")
                    } actions: {
                        Button("Add Repository…") { actions.isAddingRepository = true }
                            .buttonStyle(.borderedProminent)
                        Button("Watch a Folder of Repositories…") { isChoosingFolderToWatch = true }
                        Button("Clone Repository…") { actions.isCloning = true }
                        Button("New Repository…") { actions.isCreatingRepository = true }
                    }
                }
            }
            #if !os(macOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                modePicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            // The picker says which of the two is showing, so the bar
            // keeps a small title rather than a large one above it.
            .toolbarTitleDisplayMode(.inline)
            #endif
            // Inside the stack, so the strip sits under its bar, not over it.
            .noticeStrip(actions.notices)
            .searchable(text: $query, prompt: actions.isReviewing ? "Repository, branch, file or commit" : "Name, folder or branch")
            .navigationTitle(navigationTitle)
            .toolbar {
                // In the middle of the Mac's toolbar. An iPhone's has no
                // room beside its buttons, so there it goes under the title.
                #if os(macOS)
                ToolbarItem(placement: .principal) {
                    modePicker.fixedSize()
                }
                #endif
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

    /// The window's title on the Mac. On iOS the picker under the bar
    /// says which of the two is showing, and the bar, short of room beside
    /// its buttons, names the app.
    private var navigationTitle: String {
        #if os(macOS)
        actions.isReviewing ? "Review" : "Repositories"
        #else
        "Wye"
        #endif
    }

    /// Chooses between the list of repositories and the Review.
    private var modePicker: some View {
        @Bindable var actions = actions
        return Picker("Show", selection: $actions.isReviewing) {
            Text("Repositories").tag(false)
            Text("Review").tag(true)
        }
        .pickerStyle(.segmented)
        .help("Review everything not committed or pushed, in every repository")
        .popoverTip(library.listedBookmarks.count > 1 ? ReviewTip() : nil)
        .onChange(of: actions.isReviewing) {
            if actions.isReviewing { Task { await ReviewTip.reviewed.donate() } }
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
