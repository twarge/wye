import SwiftUI
#if os(macOS)
import FinderSync
#endif

/// Where Wye shows up outside its own windows: the menu bar and the Finder
/// on macOS, and iCloud on every device, in a build signed for it.
struct SystemSettingsSection: View {
    #if os(macOS)
    @AppStorage(MenuBarPreferences.isShownKey) private var showsMenuBarItem = false
    #endif
    @Bindable private var sync = SettingsSync.shared

    var body: some View {
        #if os(macOS)
        Section("System") {
            Toggle("Show Wye in the Menu Bar", isOn: $showsMenuBarItem)
            LabeledContent("Finder Extension") {
                Button("Extensions Settings…") {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
            }
            if SettingsSync.isAvailable() { syncToggle }
        }
        #else
        if SettingsSync.isAvailable() {
            Section("iCloud") { syncToggle }
        }
        #endif
    }

    private var syncToggle: some View {
        Toggle("Sync Settings with iCloud", isOn: $sync.isEnabled)
    }
}
