import AppIntents
import SwiftUI
import WyeUI

@main
struct WyeApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: ServicesDelegate
    #endif

    init() {
        IntentsSupport.start { WyeShortcuts.updateAppShortcutParameters() }
    }

    var body: some Scene {
        WyeScene()
    }
}

/// Brings WyeUI's intents and App Shortcuts into the app's own metadata,
/// which is where Siri, Shortcuts and Spotlight look for them.
struct WyeAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [WyeUIIntentsPackage.self]
    }
}
