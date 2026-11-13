import GitKit
import SwiftUI

/// The app's scenes. The app target is only an entry point that shows this.
public struct WyeScene: Scene {
    @State private var library = RepositoryLibrary.shared

    /// Names the repository window, so a command can open another one.
    static let windowID = "repository"
    /// Names the activity log's window, on macOS.
    static let activityWindowID = "activity"

    public init() {
        // Wye keeps its own git configuration: inside the sandbox it cannot
        // read the one in the user's home folder.
        try? GitEnvironment.useGlobalConfiguration(in: .applicationSupportDirectory.appending(path: "Wye/git"))
        // Files written for drags and shares in an earlier run.
        DragFiles.removeAll()
        // Before launch finishes, as the system wants both.
        FetchNotifications.install()
        BackgroundRefresh.register(library: RepositoryLibrary.shared)
        ContinuedWork.register()
        WidgetActionRunner.install()
        WyeTips.configure()
        SettingsSync.shared.start(library: RepositoryLibrary.shared)
    }

    public var body: some Scene {
        WindowGroup(id: Self.windowID) {
            RootView()
                .environment(library)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            WyeCommands(library: library)
            #if os(macOS)
            // View ▸ Show and Hide Inspector, for the details on the right.
            InspectorCommands()
            #endif
        }

        WindowGroup("Commit", id: Self.commitWindowID, for: CommitWindowTarget.self) { $target in
            if let target {
                CommitWindow(target: target)
                    .environment(library)
            }
        }
        .defaultSize(width: 1080, height: 760)

        #if os(macOS)
        Window("Activity", id: Self.activityWindowID) {
            ActivityView()
        }
        .defaultSize(width: 560, height: 480)

        Settings {
            SettingsView()
                // A fixed width; as tall as the user drags it.
                .frame(width: 440)
                .frame(minHeight: 320, idealHeight: 640, maxHeight: .infinity)
        }
        .windowResizability(.contentSize)

        MenuBarStatus(library: library)
        #endif
    }
}

/// One window: the list of repositories, or the repository opened from it.
struct RootView: View {
    @Environment(RepositoryLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("openRepository") private var openRepositoryID: String?
    @State private var model: RepositoryModel?
    @State private var actions = WindowActions()

    var body: some View {
        Group {
            if let model {
                RepositoryView(model: model) { close() }
                    .id(model.id)
            } else {
                RepositoryLibraryView { open($0) }
            }
        }
        // A tap when a commit or a transfer is done, another when
        // something fails: felt on iPhone, and on a trackpad on the Mac.
        .sensoryFeedback(.success, trigger: ActivityLog.shared.completions)
        .sensoryFeedback(.error, trigger: ActivityLog.shared.failures)
        .windowActions(actions, model: model)
        .handlesWyeLinks(actions)
        .settingsOpener()
        .onAppear {
            actions.open = { open($0) }
            actions.close = { close() }
        }
        .task {
            if model == nil, let id = library.openInNextWindow,
               let bookmark = library.bookmarks.first(where: { $0.id == id }) {
                library.openInNextWindow = nil
                open(bookmark)
            }
            // Reopen what this window showed when the app last quit.
            if model == nil, let bookmark = library.bookmarks.first(where: { $0.id.uuidString == openRepositoryID }) {
                open(bookmark)
            }
        }
        .onOpenURL { url in
            if let link = WyeLink(url) {
                LinkRouter.shared.request(link)
                return
            }
            if PatchFileOpening.isPatch(url) {
                openPatch(url)
                return
            }
            do {
                open(try library.add(url))
            } catch {
                actions.notices.post(error, during: "Add Repository")
            }
        }
        .task {
            BackgroundFetcher.shared.start(library: library)
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                BackgroundRefresh.schedule()
            }
            // Catch up with whatever changed while the app was in the background.
            guard scenePhase == .active else { return }
            library.syncWatchedFolders()
            guard let model else { return }
            Task { await model.refresh() }
        }
    }

    private func open(_ bookmark: RepositoryBookmark) {
        do {
            let opened = try RepositoryModel(bookmark: bookmark, access: library.access(to: bookmark))
            if let model { OpenRepositories.remove(model) }
            model = opened
            OpenRepositories.add(opened)
            openRepositoryID = bookmark.id.uuidString
            library.recordOpened(bookmark)
        } catch {
            actions.notices.post(error, during: "Open “\(bookmark.name)”")
        }
    }

    /// A patch file opened from outside: offered to the repository this
    /// window shows, as Apply Patch… offers one.
    private func openPatch(_ url: URL) {
        guard let model else {
            actions.notices.post(PatchFileOpening.NoRepository(name: url.lastPathComponent))
            return
        }
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        do {
            model.history.requests.importedPatch = ImportedPatch(name: url.lastPathComponent, data: try Data(contentsOf: url))
        } catch {
            model.report(error, during: "Open Patch")
        }
    }

    private func close() {
        if let model { OpenRepositories.remove(model) }
        model = nil
        openRepositoryID = nil
    }
}
