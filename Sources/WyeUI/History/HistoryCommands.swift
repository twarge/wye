import GitKit
import SwiftUI

/// How histories are shown, as menu items: in the View menu and in the
/// history's toolbar.
struct HistoryViewOptions: View {
    @Bindable private var preferences = HistoryPreferences.shared

    var body: some View {
        Toggle("Show Graph", isOn: $preferences.showsGraph)
        Toggle("First Parent Only", isOn: $preferences.firstParentOnly)
        Picker("Sort By", selection: $preferences.order) {
            Text("Date").tag(HistoryOptions.Order.date)
            Text("Topology").tag(HistoryOptions.Order.topological)
        }
        Picker("Group By", selection: $preferences.grouping) {
            ForEach(HistoryPreferences.Grouping.allCases) { grouping in
                Text(grouping.title).tag(grouping)
            }
        }
        if Platform.choosesHistoryRowSize {
            Picker("Row Size", selection: $preferences.rowSize) {
                ForEach(HistoryPreferences.RowSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
        }
    }
}

/// The history's part of the View menu.
struct HistoryCommands: Commands {
    var model: RepositoryModel?

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Section {
                Button("Show HEAD") {
                    Task { await model?.showHead() }
                }
                .keyboardShortcut("0")
                .disabled(model?.snapshot?.head.target == nil)
                Menu("History") {
                    HistoryViewOptions()
                }
            }
        }
    }
}
