import SwiftUI
#if os(macOS)
import AppKit
#else
import FileProvider
#endif

/// The few places where macOS and iOS genuinely differ, kept in one file so
/// the rest of the interface is written once.
enum Platform {
    /// Whether a list row has a pointer's double-click as its primary action.
    /// On iOS that action is a single tap, which rows use for selection.
    static var hasDoubleClick: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Whether the click being handled extends a selection to a range, as a
    /// shift-click does with a pointer. A tap on a touch screen never does:
    /// each tap adds or removes one item.
    @MainActor static var isExtendingSelection: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    /// What happens to untracked files whose changes are discarded, for the
    /// confirmation that asks first. macOS has a Trash to move them to.
    static var untrackedDiscardNote: String {
        #if os(macOS)
        "Untracked files are moved to the Trash."
        #else
        "Untracked files are deleted."
        #endif
    }

    /// Whether the click being handled is an Option-click, which opens a
    /// command's options instead of running it. iOS uses a long press.
    @MainActor static var isOptionClick: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }

    /// Whether a clone goes into a folder the user picks. On iOS clones go
    /// into Wye's own location in the Files app, where other apps can open
    /// them (`RepositoryLibrary.newRepositoryFolder`).
    static var clonesIntoChosenFolder: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Whether a new worktree goes into a folder the user picks, which is
    /// what grants Wye access to it. On iOS worktrees go into Wye's own
    /// location in the Files app, where Wye can write without asking.
    static var placesWorktreesInChosenFolder: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Whether a submodule or worktree opens in a new tab beside its
    /// repository. On iOS it takes the window's place, as opening any
    /// repository there does.
    static var opensNestedRepositoriesInNewTab: Bool {
        hasWindowTabs
    }

    /// Whether a file can be shown in the system's file browser. macOS has
    /// the Finder; iOS has no public way to open the Files app at a file.
    static var canRevealFiles: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Where a placeholder sits to line up with a text editor's first line:
    /// the text view insets its text differently on each platform.
    static var textEditorPlaceholderInsets: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 0)
        #else
        EdgeInsets(top: 8, leading: 5, bottom: 0, trailing: 0)
        #endif
    }

    /// The space between a text editor and the border drawn round it.
    static var textEditorFieldPadding: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        #else
        EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 3)
        #endif
    }

    static var revealInFileBrowserTitle: String { "Reveal in Finder" }

    /// Shows a file selected in the Finder.
    @MainActor static func revealInFileBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    /// Whether a file can be opened in the app the system picks for it.
    /// iOS opens files from Quick Look's share button instead.
    static var canOpenFilesInOtherApps: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    @MainActor static func openWithDefaultApp(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// What removing an untracked file is called: there is a Trash only on macOS.
    static var trashTitle: String {
        #if os(macOS)
        "Move to Trash"
        #else
        "Delete"
        #endif
    }

    /// What happens to an untracked file removed from its menu, for the
    /// confirmation that asks first.
    static var trashNote: String {
        #if os(macOS)
        "It is moved to the Trash, where it can be put back from."
        #else
        "It is deleted and cannot be recovered."
        #endif
    }

    /// Puts text on the clipboard, which each platform names differently.
    @MainActor static func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// The device's name, for the comment of a new SSH key, so that the
    /// key can be told apart on the hosting service. iOS gives only the
    /// model's name to apps.
    @MainActor static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}

extension Font {
    /// The font for hashes, diffs and other text that lines up in columns.
    static var code: Font {
        #if os(macOS)
        .system(size: 12, design: .monospaced)
        #else
        .system(.footnote, design: .monospaced)
        #endif
    }

    static var smallCode: Font {
        #if os(macOS)
        .system(size: 11, design: .monospaced)
        #else
        .system(.caption, design: .monospaced)
        #endif
    }
}

extension View {
    /// Puts Fetch, Pull and Push where each platform has room: the window
    /// toolbar on macOS; on iOS a floating bar at the bottom of the content,
    /// where the navigation bar has little room to spare.
    ///
    /// On iOS the bar is a safe area inset rather than a bottom toolbar: a
    /// list then scrolls its last rows clear of it, which it did not do
    /// under the toolbar on iPad. It is SwiftUI content too, so its counts
    /// change with the branch; a bottom toolbar's badges, bridged to bar
    /// button items, kept the count they were created with.
    @ViewBuilder
    func remoteBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        #if os(macOS)
        toolbar {
            ToolbarItemGroup(placement: .primaryAction) { bar() }
        }
        #else
        safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 20) { bar() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .imageScale(.large)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
        }
        #endif
    }

    /// A count on a Fetch, Pull or Push button: a toolbar badge on macOS,
    /// drawn on the button in the iOS bar, where buttons have no badges.
    @ViewBuilder
    func remoteCount(_ count: Int) -> some View {
        #if os(macOS)
        badge(count)
        #else
        overlay(alignment: .topTrailing) {
            if count > 0 {
                Text(count.formatted())
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red, in: .capsule)
                    .offset(x: 10, y: -8)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityValue(count > 0 ? "\(count)" : "")
        #endif
    }

    /// Leaves letter case alone, for usernames, tokens and URLs. Only iOS
    /// capitalizes as the user types.
    func noAutocapitalization() -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(.never)
        #endif
    }
}

extension URL {
    /// Bookmark data that lets the app reopen a folder the user picked. Only
    /// macOS distinguishes security-scoped bookmarks; on iOS every bookmark to
    /// a picked folder carries its access.
    func repositoryBookmark() throws -> Data {
        #if os(macOS)
        try bookmarkData(options: .withSecurityScope)
        #else
        try bookmarkData()
        #endif
    }

    init(resolvingRepositoryBookmark data: Data, isStale: inout Bool) throws {
        #if os(macOS)
        try self.init(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
        #else
        try self.init(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        #endif
    }
}

/// A button that opens the app's settings: the Settings window on macOS, a
/// sheet on iOS, where an app has no settings window of its own.
struct SettingsButton<Label: View>: View {
    @ViewBuilder var label: Label
    @State private var isPresented = false

    var body: some View {
        #if os(macOS)
        SettingsLink { label }
        #else
        Button { isPresented = true } label: { label }
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isPresented = false }
                            }
                        }
                }
            }
        #endif
    }
}

extension View {
    /// The smallest a sheet may be. A Mac sheet is as small as its content
    /// unless given a size; an iOS sheet fills the screen or its card, where a
    /// minimum wider than an iPhone would push the content off it.
    func sheetMinimumSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }
}

// MARK: Window tabs

extension Platform {
    /// Whether windows can be gathered into tabs. Only macOS has window tabs;
    /// on iPad each window is its own scene.
    static var hasWindowTabs: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Whether the app has windows besides its repository windows, such as
    /// the activity log; iOS shows those as sheets.
    static var hasAuxiliaryWindows: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Opens a new window with `open` and attaches it to the front window as
    /// a tab. SwiftUI can open a window but has no way to say "as a tab".
    @MainActor
    static func openAsTab(_ open: () -> Void) {
        #if os(macOS)
        let front = NSApp.keyWindow
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        open()
        Task { @MainActor in
            // The new window exists a moment after it is asked for.
            for _ in 0..<20 {
                let fresh = NSApp.windows.first {
                    !existing.contains(ObjectIdentifier($0)) && $0.canBecomeMain && $0.tabbingMode != .disallowed
                }
                if let front, let fresh {
                    if fresh.tabGroup !== front.tabGroup || front.tabGroup == nil {
                        front.addTabbedWindow(fresh, ordered: .above)
                    }
                    fresh.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        #else
        open()
        #endif
    }
}

// MARK: Undo

extension Platform {
    /// Whether the Edit menu's own Undo and Redo give way to Wye's. On macOS
    /// they do, and hand ⌘Z on to a text field that has focus. On iOS the
    /// system's stay, for text, and Wye's follow them without shortcuts,
    /// with an Undo button in the toolbar besides.
    static var replacesUndoMenu: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Whether the repository window shows Undo and Redo buttons.
    static var showsUndoButtons: Bool {
        !replacesUndoMenu
    }

    static var undoButtonPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .secondaryAction
        #endif
    }
}

/// The undo state of the text being edited, if any: what the Edit menu
/// offers instead of Wye's own undo while a text field has focus.
@MainActor
@Observable
final class TextEditingUndo {
    static let shared = TextEditingUndo()

    /// Whether a text field or text view has focus.
    private(set) var isEditing = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var undoTitle = "Undo"
    private(set) var redoTitle = "Redo"

    private init() {
        #if os(macOS)
        // After every event, as AppKit itself validates its menus.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TextEditingUndo.shared.update() }
        }
        #endif
    }

    /// Undoes or redoes in the text that has focus.
    func perform(redo: Bool) {
        #if os(macOS)
        NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil)
        #endif
    }

    #if os(macOS)
    private func update() {
        let text = NSApp.keyWindow?.firstResponder as? NSText
        let manager = text?.undoManager
        set(\.isEditing, text != nil)
        set(\.canUndo, manager?.canUndo ?? false)
        set(\.canRedo, manager?.canRedo ?? false)
        set(\.undoTitle, manager?.undoMenuItemTitle ?? "Undo")
        set(\.redoTitle, manager?.redoMenuItemTitle ?? "Redo")
    }

    /// Assigns only real changes, so the menu is not rebuilt after every event.
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TextEditingUndo, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
    #endif
}

// MARK: History

extension Platform {
    /// Whether the history offers compact and regular rows. iOS chooses by
    /// the width it has.
    static var choosesHistoryRowSize: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Whether choosing several rows takes an edit mode, as on iOS, rather
    /// than Shift- and Command-clicks.
    static var selectsSeveralInEditMode: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }
}

/// Turns on choosing several rows, where that takes an edit mode.
struct SelectionModeButton: View {
    var body: some View {
        #if os(macOS)
        EmptyView()
        #else
        EditButton()
        #endif
    }
}

// MARK: Home folder

extension Platform {
    /// The user's own home folder. Inside the sandbox `URL.homeDirectory` is
    /// the app's container, so on macOS the real one is looked up from the
    /// account. The app cannot read it; a file dialog can start there.
    static var userHomeDirectory: URL {
        #if os(macOS)
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
            return URL(filePath: String(cString: path), directoryHint: .isDirectory)
        }
        #endif
        return .homeDirectory
    }
}

// MARK: Showing the settings

extension View {
    /// Shows the settings when something asks ``SettingsFocus`` for them:
    /// the Settings window on macOS, a sheet on iOS.
    func settingsOpener() -> some View {
        modifier(SettingsOpener())
    }
}

private struct SettingsOpener: ViewModifier {
    @State private var focus = SettingsFocus.shared
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: focus.requests) { openSettings() }
        #else
        content.sheet(isPresented: $focus.isPresented) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { focus.isPresented = false }
                        }
                    }
            }
        }
        #endif
    }
}

// MARK: Code text

extension Platform {
    /// The point size code is drawn at until the reader picks another: the
    /// size of `Font.code` on each platform.
    static var defaultCodeFontSize: Double {
        #if os(macOS)
        12
        #else
        13
        #endif
    }

    /// Whether a diff or file shows a Find button. On macOS Find is in the
    /// Edit menu with its shortcut; on iOS a button is the way to reach it.
    static var showsFindButton: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }
}

// MARK: Files location

extension Platform {
    /// Whether Wye's repositories have a location of their own in the
    /// system's file browser, through the File Provider extension. Only iOS
    /// has one: on macOS repositories are wherever the user keeps them, and
    /// the Finder shows them there.
    static var hasFilesLocation: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    /// Asks the Files app to list these folders of the location again, by
    /// their identifiers (`nil` for the top level).
    static func signalFilesLocation(_ identifiers: [String?]) {
        #if os(iOS)
        for identifier in identifiers {
            let item = identifier.map(NSFileProviderItemIdentifier.init(rawValue:)) ?? .rootContainer
            NSFileProviderManager.default.signalEnumerator(for: item) { _ in
                // Nothing to do when no one is looking at the folder.
            }
        }
        #endif
    }
}
