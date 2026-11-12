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
        Section {
            Toggle("Show Wye in the Menu Bar", isOn: $showsMenuBarItem)
            LabeledContent("Finder Extension") {
                Button("Extensions Settings…") {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
            }
        } header: {
            Text("Menu Bar and Finder")
        } footer: {
            Text("The menu bar item lists the repositories with something to push, pull or commit. The Finder extension, once turned on in System Settings, badges changed files in the repositories Wye lists and adds Open in Wye to Finder’s menus.")
        }
        #endif
        if SettingsSync.isAvailable() {
            Section {
                Toggle("Sync Settings with iCloud", isOn: $sync.isEnabled)
            } header: {
                Text("iCloud")
            } footer: {
                Text("Keeps repository groups, author profiles and these settings the same on your devices. What iCloud already has replaces what is set here. Repositories themselves, accounts and keys are not included.")
            }
        }
    }
}
