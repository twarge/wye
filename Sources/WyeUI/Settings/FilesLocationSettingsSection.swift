import SwiftUI

/// Where other apps find Wye's repositories, on iOS.
struct FilesLocationSettingsSection: View {
    var body: some View {
        if Platform.hasFilesLocation {
            Section("Files App") {
                Text("Repositories cloned or created in Wye are in the Files app, under Wye in the sidebar, where other apps can open a repository’s folder or files and edit them in place. Each repository’s .git folder is hidden there, so git’s own data cannot be changed by mistake.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
