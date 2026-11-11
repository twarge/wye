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
        try? GitEnvironment.useGlobalConfiguration(in: .applicationSupportDirectory.appending(path: "Twig/git"))
        // Before launch finishes, as the system wants both.
        FetchNotifications.install()
        BackgroundRefresh.register(library: RepositoryLibrary.shared)
    }

    public var body: some Scene {
        WindowGroup(id: Self.windowID) {
            RootView()
                .environment(library)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            WyeCommands(library: library)
        }

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
        #endif
    }
}

/// One window: the list of repositories, or the repository opened from it.
struct RootView: View {
    @Environment(RepositoryLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("openRepository") private var openRepositoryID: String?
    @State private var model: RepositoryModel?
    @State private var error: PresentedError?
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
        .alert(for: $error)
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
            do {
                open(try library.add(url))
            } catch {
                self.error = PresentedError(error)
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
            self.error = PresentedError(error)
        }
    }

    private func close() {
        if let model { OpenRepositories.remove(model) }
        model = nil
        openRepositoryID = nil
    }
}
