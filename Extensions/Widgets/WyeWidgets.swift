import AppIntents
import SwiftUI
import WidgetKit
import WyeShared

@main
struct WyeWidgets: WidgetBundle {
    var body: some Widget {
        UnpushedChangesWidget()
        RepositoryWidget()
        FetchAllControl()
    }
}

/// Brings the shared intents the widgets' buttons run into the extension's
/// own metadata, as the app does for its own.
struct WyeWidgetsIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [WyeSharedIntentsPackage.self]
    }
}
