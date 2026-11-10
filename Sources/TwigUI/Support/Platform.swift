import SwiftUI

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

    /// Where Fetch, Pull and Push go: the window toolbar on macOS, and the
    /// bottom bar on iOS, where the navigation bar has little room to spare.
    static var remoteToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .bottomBar
        #endif
    }

    /// Whether a clone goes into a folder the user picks. On iOS clones go
    /// into the app's Documents, where the Files app shows them.
    static var clonesIntoChosenFolder: Bool {
        #if os(macOS)
        true
        #else
        false
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
