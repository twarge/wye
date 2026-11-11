import SwiftUI

/// The Submodules section of Settings: whether submodules follow an
/// operation that changes the commits recorded for them.
struct SubmoduleSettingsSection: View {
    @AppStorage(SubmodulePreferences.autoUpdateKey) private var autoUpdate = SubmoduleUpdatePolicy.ask

    var body: some View {
        Section {
            Picker("Update After Changes", selection: $autoUpdate) {
                ForEach(SubmoduleUpdatePolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
        } header: {
            Text("Submodules")
        } footer: {
            Text("When a checkout, pull, merge, rebase or reset changes the commit a repository records for a submodule, "
                 + "Wye can check the submodule out at it, cloning it if needed.")
        }
    }
}
