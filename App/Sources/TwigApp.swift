import AppIntents
import SwiftUI
import TwigUI

@main
struct TwigApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: ServicesDelegate
    #endif

    init() {
        IntentsSupport.start { TwigShortcuts.updateAppShortcutParameters() }
    }

    var body: some Scene {
        TwigScene()
    }
}

/// Brings TwigUI's intents and App Shortcuts into the app's own metadata,
/// which is where Siri, Shortcuts and Spotlight look for them.
struct TwigAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [TwigUIIntentsPackage.self]
    }
}
