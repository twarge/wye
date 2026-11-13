import GitKit
import SwiftUI

/// How histories are shown, as menu items: in the View menu, in the
/// history's toolbar, and on a right-click below its rows.
struct HistoryViewOptions: View {
    @Bindable private var preferences = HistoryPreferences.shared

    var body: some View {
        HistoryRowOptions()
        Toggle("First Parent Only", isOn: $preferences.firstParentOnly)
        Picker("Sort By", selection: $preferences.order) {
            Text("Date").tag(HistoryOptions.Order.date)
            Text("Topology").tag(HistoryOptions.Order.topological)
        }
        HistoryGroupingPicker()
        if Platform.choosesHistoryRowSize {
            Picker("Row Size", selection: $preferences.rowSize) {
                ForEach(HistoryPreferences.RowSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
        }
    }
}

/// What a history's rows show, as menu items, in the order a row shows
/// them: also at the foot of a commit's context menu.
struct HistoryRowOptions: View {
    @Bindable private var preferences = HistoryPreferences.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Toggle("Show Graph", isOn: $preferences.showsGraph)
        Toggle("Show Commit Hash", isOn: $preferences.showsHash)
        // Rows on two lines always show the author.
        if sizeClass != .compact {
            Toggle("Show Author", isOn: $preferences.showsAuthor)
        }
        Toggle("Show Commit Date", isOn: $preferences.showsDate)
    }
}

/// The headings that split a history by day, week or month, or none.
struct HistoryGroupingPicker: View {
    @Bindable private var preferences = HistoryPreferences.shared

    var body: some View {
        Picker("Group By", selection: $preferences.grouping) {
            ForEach(HistoryPreferences.Grouping.allCases) { grouping in
                Text(grouping.title).tag(grouping)
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
