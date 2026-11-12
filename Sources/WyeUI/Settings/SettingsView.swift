import GitKit
import SwiftUI

struct SettingsView: View {
    @State private var focus = SettingsFocus.shared

    var body: some View {
        ScrollViewReader { proxy in
            form
                // Also when the settings are already open and asked for again.
                .onChange(of: focus.requests, initial: true) {
                    guard focus.sshKeyNotice != nil else { return }
                    Task {
                        // Once the notice's row has been laid out.
                        try? await Task.sleep(for: .milliseconds(200))
                        withMotion {
                            proxy.scrollTo(SettingsFocus.sshKeysAnchor, anchor: .top)
                        }
                    }
                }
        }
        .onDisappear {
            focus.sshKeyNotice = nil
        }
    }

    private var form: some View {
        Form {
            IdentitySettingsSection()
            DiffSettingsSection()
            AppearanceSettingsSection()
            CommittingSettingsSection()
            FetchSettingsSection()
            PullSettingsSection()
            PushSettingsSection()
            BranchSettingsSection()
            NewRepositorySettingsSection()
            SubmoduleSettingsSection()
            FilesLocationSettingsSection()
            SystemSettingsSection()

            AccountsSection()
            SSHKeysSection()

            Section("About") {
                LabeledContent("libgit2", value: GitEnvironment.libgit2Version)
                AcknowledgementsButton()
            }
        }
        .formStyle(.grouped)
    }
}
