import SwiftUI

/// The last row of a shortened list, which lists the rest.
struct ShowAllRow: View {
    var title: LocalizedStringKey
    var showAll: () -> Void

    var body: some View {
        Button(action: showAll) {
            Text(title)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
        .selectionDisabled()
    }
}

/// The sort choices for a sidebar section, in the View menu.
struct SidebarSortPicker: View {
    var title: LocalizedStringKey
    var selection: SidebarSort
    var choose: (SidebarSort) -> Void

    var body: some View {
        Picker(title, selection: Binding { selection } set: { choose($0) }) {
            ForEach(SidebarSort.allCases) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .pickerStyle(.menu)
    }
}

/// View ▸ the sidebar's sort orders, and putting a long list back to its
/// first few after Show All or More tags….
struct SidebarListCommands: View {
    var model: RepositoryModel?

    var body: some View {
        let lists = model?.interface.sidebarLists ?? SidebarListOptions()
        SidebarSortPicker(title: "Sort Remote Branches By", selection: lists.remoteBranchSort) {
            var lists = lists
            lists.remoteBranchSort = $0
            model?.interface.setSidebarLists(lists)
        }
        .disabled(model == nil)
        SidebarSortPicker(title: "Sort Tags By", selection: lists.tagSort) {
            var lists = lists
            lists.tagSort = $0
            model?.interface.setSidebarLists(lists)
        }
        .disabled(model == nil)
        Button("Show Fewer Tags and Remote Branches") {
            var lists = lists
            lists.remotesShowingAll = []
            lists.showsAllTags = false
            model?.interface.setSidebarLists(lists)
        }
        .disabled(lists.remotesShowingAll.isEmpty && !lists.showsAllTags)
        .help("List only the most recent tags and the first remote branches again, after More tags… or Show All")
    }
}
