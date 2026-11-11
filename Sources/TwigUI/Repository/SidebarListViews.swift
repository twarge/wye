import SwiftUI

/// The last row of a shortened list, which lists the rest.
struct ShowAllRow: View {
    var count: Int
    var showAll: () -> Void

    var body: some View {
        Button(action: showAll) {
            Text("Show All (\(count.formatted()))")
                .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
        .selectionDisabled()
    }
}

/// The sort choices in a sidebar section's menu.
struct SidebarSortPicker: View {
    var title: String
    var selection: SidebarSort
    var choose: (SidebarSort) -> Void

    var body: some View {
        Picker(title, selection: Binding { selection } set: { choose($0) }) {
            ForEach(SidebarSort.allCases) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .pickerStyle(.inline)
    }
}
