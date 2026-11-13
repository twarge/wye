import SwiftUI

/// The Sidebar section of Settings: how many tags it lists.
struct SidebarSettingsSection: View {
    @AppStorage(SidebarPreferences.tagLimitKey) private var tagLimit = SidebarPreferences.defaultTagLimit

    var body: some View {
        Section {
            Stepper(value: $tagLimit, in: SidebarPreferences.tagLimitRange) {
                LabeledContent("Tags Listed", value: SidebarPreferences.tagLimit(tagLimit).formatted())
            }
        } header: {
            Text("Sidebar")
        } footer: {
            Text("The most recent tags, by the dates of their commits. With more than these, More tags… at the "
                 + "end of the list shows the rest.")
        }
    }
}
