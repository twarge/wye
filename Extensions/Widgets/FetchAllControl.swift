import AppIntents
import SwiftUI
import WidgetKit
import WyeShared

/// Fetch All as a control: in Control Center, on the Lock Screen and the
/// Action button on iOS, in Control Center and the menu bar on macOS.
struct FetchAllControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "FetchAll") {
            ControlWidgetButton(action: WidgetFetchAllIntent()) {
                Label("Fetch All", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .displayName("Fetch All Repositories")
        .description("Fetches every repository in Wye.")
    }
}
