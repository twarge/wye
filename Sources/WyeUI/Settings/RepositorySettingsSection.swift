import SwiftUI

/// The Repositories section of Settings: the branch a new repository
/// starts on, when a branch counts as stale and when one is archived
/// without being asked, how many tags the sidebar lists, and whether
/// submodules follow an operation that changes the commits recorded for
/// them.
struct RepositorySettingsSection: View {
    @AppStorage(NewRepositoryPreferences.defaultBranchKey) private var defaultBranch = NewRepositoryPreferences.standardBranch
    @AppStorage(BranchPreferences.staleMonthsKey) private var staleMonths = 3
    @AppStorage(BranchPreferences.autoArchiveMonthsKey) private var autoArchiveMonths = 0
    @AppStorage(SidebarPreferences.tagLimitKey) private var tagLimit = SidebarPreferences.defaultTagLimit
    @AppStorage(SubmodulePreferences.autoUpdateKey) private var autoUpdate = SubmoduleUpdatePolicy.ask

    var body: some View {
        Section("Repositories") {
            // Labeled apart from the field: on iOS a field's own title is
            // only its placeholder, and this one is never empty.
            LabeledContent("New Repositories Start On") {
                TextField("Branch", text: $defaultBranch, prompt: Text(NewRepositoryPreferences.standardBranch))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
            }
            Picker("Mark Branches as Stale After", selection: $staleMonths) {
                ForEach(BranchPreferences.staleChoices, id: \.self) { months in
                    Text(months == 0 ? "Never" : Self.months(months)).tag(months)
                }
            }
            Picker("Archive Branches After", selection: $autoArchiveMonths) {
                ForEach(BranchPreferences.autoArchiveChoices, id: \.self) { months in
                    Text(months == 0 ? "Never" : Self.months(months)).tag(months)
                }
            }
            Stepper(value: $tagLimit, in: SidebarPreferences.tagLimitRange) {
                LabeledContent("Tags in the Sidebar", value: SidebarPreferences.tagLimit(tagLimit).formatted())
            }
            Picker("Update Submodules After Changes", selection: $autoUpdate) {
                ForEach(SubmoduleUpdatePolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
        }
    }

    private static func months(_ count: Int) -> String {
        count == 1 ? "1 Month" : "\(count) Months"
    }
}

enum NewRepositoryPreferences {
    static let defaultBranchKey = "newRepository.defaultBranch"
    static let standardBranch = "main"

    static var defaultBranch: String {
        let saved = UserDefaults.standard.string(forKey: defaultBranchKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty ? standardBranch : saved
    }
}
