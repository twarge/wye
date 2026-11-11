import SwiftUI

/// The Branches section of Settings: when a branch counts as stale, and
/// when one is archived without being asked.
struct BranchSettingsSection: View {
    @AppStorage(BranchPreferences.staleMonthsKey) private var staleMonths = 3
    @AppStorage(BranchPreferences.autoArchiveMonthsKey) private var autoArchiveMonths = 0

    var body: some View {
        Section {
            Picker("Mark as Stale After", selection: $staleMonths) {
                ForEach(BranchPreferences.staleChoices, id: \.self) { months in
                    Text(months == 0 ? "Never" : Self.months(months)).tag(months)
                }
            }
            Picker("Archive Automatically After", selection: $autoArchiveMonths) {
                ForEach(BranchPreferences.autoArchiveChoices, id: \.self) { months in
                    Text(months == 0 ? "Never" : Self.months(months)).tag(months)
                }
            }
        } header: {
            Text("Branches")
        } footer: {
            Text("Counted from a branch’s last commit. Archived branches move to their own section of the sidebar; "
                 + "the branches themselves are not changed. A branch’s menu can exempt it, and the checked-out "
                 + "and pinned branches are never archived automatically.")
        }
    }

    private static func months(_ count: Int) -> String {
        count == 1 ? "1 Month" : "\(count) Months"
    }
}
