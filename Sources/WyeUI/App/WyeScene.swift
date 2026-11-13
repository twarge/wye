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
        #if os(macOS)
        // Windows come back after Quit as they were left, commit windows and
        // tabs too, as a repository's folder would in the Finder. Out of the
        // box the Mac closes an app's windows when it quits; this is only
        // Wye's default, so a choice made in System Settings ▸ Desktop & Dock
        // still wins.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": true])
        #endif
        // Wye keeps its own git configuration: inside the sandbox it cannot
        // read the one in the user's home folder.
        try? GitEnvironment.useGlobalConfiguration(in: .applicationSupportDirectory.appending(path: "Wye/git"))
        // Files written for drags, shares and previews in an earlier run.
        DragFiles.removeAll()
        PreviewFiles.removeAll()
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
        // With the sidebar at its narrowest and the list of commits at its
        // usual 490 points, the details have about 560.
        .defaultSize(width: 1220, height: 780)
        .commands {
            WyeCommands(library: library)
            #if os(macOS)
            // View ▸ Show and Hide Details, for the details on the right.
            DetailCommands()
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
    /// What the window shows in its repository, as `SavedWindow` keeps it.
    @SceneStorage("windowView") private var savedView: String?
    /// Set once the window has opened: true from the start in a window the
    /// system restored, even one showing the list of repositories.
    @SceneStorage("hasOpened") private var hasOpened = false
    @State private var model: RepositoryModel?
    /// A repository opened and not on screen yet. See `open(_:restoring:)`.
    @State private var arriving: RepositoryModel?
    /// Whether the window has yet to show what it reopens with. Until it
    /// has, one that showed a repository when the app quit shows nothing,
    /// for the moment that takes: the list of repositories would be built
    /// and would start reading every repository's status, only to be
    /// replaced.
    @State private var isReopening = true
    /// Whether `WindowRestoration.openWindows` counts this window yet.
    @State private var isCounted = false
    @State private var actions = WindowActions()

    var body: some View {
        Group {
            if let model {
                RepositoryView(model: model) { close() }
                    .id(model.id)
            } else if isReopening, reopensRepository {
                Color.clear
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
            WindowRestoration.openWindows += 1
            isCounted = true
        }
        .onDisappear {
            WindowRestoration.openWindows -= 1
            // The last window closed is the one a new window reopens.
            if WindowRestoration.openWindows == 0 {
                WindowRestoration.last = model.map(SavedWindow.init)
            }
        }
        .task {
            let isNew = !hasOpened
            hasOpened = true
            if !isOpening, let id = library.openInNextWindow,
               let bookmark = library.bookmarks.first(where: { $0.id == id }) {
                library.openInNextWindow = nil
                open(bookmark)
            }
            // Reopen what this window showed when the app last quit.
            if !isOpening, let bookmark = library.bookmarks.first(where: { $0.id.uuidString == openRepositoryID }) {
                open(bookmark, restoring: SavedWindow(encoded: savedView))
            }
            // A new window, the only one open, with nothing of its own to
            // restore: the window last seen. A new window beside others
            // shows the list of repositories.
            if !isOpening, isNew, WindowRestoration.openWindows == 1, let last = WindowRestoration.last,
               let bookmark = library.bookmarks.first(where: { $0.id == last.repository }) {
                open(bookmark, restoring: last)
            }
            // Nothing to reopen, or it could not be: the list of repositories.
            if arriving == nil { isReopening = false }
        }
        .onChange(of: model.map(SavedWindow.init)) { old, new in
            savedView = new?.encoded
            if let new {
                WindowRestoration.last = new
            } else if WindowRestoration.last?.repository == old?.repository {
                // Back to the list of repositories.
                WindowRestoration.last = nil
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

    /// Opens a repository in this window, showing what `saved` says when it
    /// is for the same repository.
    ///
    /// The window turns to it once its references and the top of its
    /// history are read, which begins at once and is a matter of
    /// milliseconds: it arrives with its sidebar and history in place,
    /// laid out once, where an empty one would fill in piece by piece. A
    /// repository slow to read is shown without them after a moment.
    private func open(_ bookmark: RepositoryBookmark, restoring saved: SavedWindow? = nil) {
        do {
            let opened = try RepositoryModel(bookmark: bookmark, access: library.access(to: bookmark))
            if let saved { opened.restore(saved) }
            opened.beginLoading()
            arriving = opened
            Task {
                await opened.finishLoading()
                show(opened)
            }
            Task {
                try? await Task.sleep(for: Self.longestWait)
                show(opened)
            }
        } catch {
            actions.notices.post(error, during: "Open “\(bookmark.name)”")
        }
    }

    /// Whether the window is about to open a repository by itself, going by
    /// what its first task looks at: one being read, the one it showed when
    /// the app quit, the one a new tab was opened for, or the window last
    /// seen when this is the only one.
    private var reopensRepository: Bool {
        if arriving != nil || openRepositoryID != nil || library.openInNextWindow != nil { return true }
        let otherWindows = WindowRestoration.openWindows - (isCounted ? 1 : 0)
        return !hasOpened && otherWindows == 0 && WindowRestoration.last != nil
    }

    /// How long a click on a repository waits for it to be read before the
    /// window turns to it regardless.
    private static let longestWait = Duration.milliseconds(200)

    /// Whether the window shows a repository or is about to.
    private var isOpening: Bool {
        model != nil || arriving != nil
    }

    /// Turns the window to a repository `open(_:restoring:)` opened, unless
    /// it has done so already or another has been opened since.
    private func show(_ opened: RepositoryModel) {
        guard arriving === opened else { return }
        arriving = nil
        isReopening = false
        if let model { OpenRepositories.remove(model) }
        model = opened
        OpenRepositories.add(opened)
        openRepositoryID = opened.bookmark.id.uuidString
        library.recordOpened(opened.bookmark)
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
        arriving = nil
        isReopening = false
        openRepositoryID = nil
    }
}
