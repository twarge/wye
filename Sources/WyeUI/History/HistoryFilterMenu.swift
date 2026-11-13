import GitKit
import SwiftUI

/// The menu that filters the history by date, author and branch, in the
/// toolbar's More menu. Each filter then shows as a token in the search
/// field. The history shows its date sheet (`historyFilterSheets(_:)`).
struct HistoryFilterMenu: View {
    var model: RepositoryModel
    @Bindable var search: SearchModel

    var body: some View {
        Menu("Filter", systemImage: search.filters.isEmpty
             ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
            Menu("Date", systemImage: "calendar") {
                ForEach(HistoryFilters.RecentRange.allCases) { range in
                    Button(range.title) {
                        search.filters.since = range.start(before: .now)
                        search.filters.until = nil
                    }
                }
                Divider()
                Button("Choose Dates…") { search.isChoosingDates = true }
                if search.filters.since != nil || search.filters.until != nil {
                    Divider()
                    Button("Any Date") {
                        search.filters.since = nil
                        search.filters.until = nil
                    }
                }
            }

            Menu("Author", systemImage: "person") {
                let authors = authors
                if authors.isEmpty {
                    Text("No Authors Yet")
                }
                ForEach(authors, id: \.self) { author in
                    Toggle(isOn: Binding {
                        search.filters.authors.contains(author)
                    } set: { _ in
                        search.filters.toggle(author)
                    }) {
                        Text(author.name.isEmpty ? author.email : author.name)
                    }
                    .help(author.email)
                }
            }

            let branches = model.snapshot?.branches ?? []
            Menu("Show Only Branches", systemImage: "arrow.triangle.branch") {
                ForEach(branches) { branch in
                    Toggle(branch.name, isOn: Binding {
                        search.filters.shownBranches.contains(branch.id)
                    } set: { _ in
                        search.filters.toggleShown(branch.id)
                    })
                }
            }
            .disabled(branches.isEmpty || model.selection != .history)
            .help("List only the commits these branches lead to")
            Menu("Hide Branches", systemImage: "eye.slash") {
                ForEach(branches) { branch in
                    Toggle(branch.name, isOn: Binding {
                        search.filters.hiddenBranches.contains(branch.id)
                    } set: { _ in
                        search.filters.toggleHidden(branch.id)
                    })
                }
            }
            .disabled(branches.isEmpty)
            .help("Leave out the commits these branches lead to")

            Divider()
            Button("Clear Search and Filters", systemImage: "xmark.circle") {
                search.text = ""
                search.filters = HistoryFilters()
            }
            .disabled(!search.hasAnything)
        }
        .help("Filter the history by date, author or branch")
    }

    /// The authors of the commits read so far, and any already chosen.
    private var authors: [HistoryFilter.Author] {
        let history = model.history
        // The newest few thousand say enough about who works here, and
        // the menu is built again whenever the toolbar is.
        let seen = HistoryFilters.authors(of: Array(history.loadedCommits.prefix(3_000)) + history.search.results)
        let chosen = search.filters.authors.subtracting(seen).sorted()
        return chosen + seen
    }
}

extension View {
    /// The sheet the filter menu's Choose Dates… asks for.
    func historyFilterSheets(_ search: SearchModel) -> some View {
        modifier(HistoryFilterSheets(search: search))
    }
}

private struct HistoryFilterSheets: ViewModifier {
    @Bindable var search: SearchModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: $search.isChoosingDates) {
            DateRangeSheet(since: search.filters.since, until: search.filters.until) { since, until in
                search.filters.since = since
                search.filters.until = until
            }
        }
    }
}

/// Chooses the first and last days of the history to list.
private struct DateRangeSheet: View {
    var apply: (Date?, Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hasStart: Bool
    @State private var start: Date
    @State private var hasEnd: Bool
    @State private var end: Date

    init(since: Date?, until: Date?, apply: @escaping (Date?, Date?) -> Void) {
        self.apply = apply
        let calendar = Calendar.current
        _hasStart = State(initialValue: since != nil || until == nil)
        _start = State(initialValue: since ?? calendar.date(byAdding: .month, value: -1, to: .now) ?? .now)
        _hasEnd = State(initialValue: until != nil)
        _end = State(initialValue: until ?? .now)
    }

    var body: some View {
        SheetStack("Dates") {
            Form {
                SheetTitleSection()
                Section {
                    Toggle("From", isOn: $hasStart)
                    if hasStart {
                        DatePicker("First Day", selection: $start, displayedComponents: .date)
                    }
                }
                Section {
                    Toggle("Until", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("Last Day", selection: $end, in: (hasStart ? start : .distantPast)...,
                                   displayedComponents: .date)
                    }
                }
            }
            .groupedFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Filter") {
                        let calendar = Calendar.current
                        // Whole days: from the start of the first to the end of the last.
                        let since = hasStart ? calendar.startOfDay(for: start) : nil
                        let until = hasEnd
                            ? calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: end))
                            : nil
                        apply(since, until)
                        dismiss()
                    }
                    .disabled(!hasStart && !hasEnd)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 260)
    }
}
