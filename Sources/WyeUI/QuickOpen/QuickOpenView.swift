import SwiftUI

/// A list to filter by typing: the arrow keys move through it, Return goes
/// to the highlighted item, Escape closes it.
struct QuickOpenView: View {
    var purpose: QuickOpenPurpose
    var currentBranch: String?
    var items: [QuickOpenItem]
    /// Called with the chosen item, and whether a repository should open in
    /// a new tab rather than in this window.
    var choose: (QuickOpenItem, _ inNewTab: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted: QuickOpenItem.ID?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let results = self.results
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if query.allSatisfy(\.isWhitespace) {
                        // Nothing typed: everything, under its heading.
                        ForEach(sections(of: results), id: \.section) { group in
                            Section(group.section.title) {
                                rows(group.results, highlighted: highlightedID(in: results))
                            }
                        }
                    } else {
                        rows(results, highlighted: highlightedID(in: results))
                    }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) {
                    if let highlighted { proxy.scrollTo(highlighted) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                searchField
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if purpose == .jump, Platform.hasWindowTabs {
                    Text("⌘↩ opens a repository in a new tab")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
            .overlay {
                if results.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("Nothing to Choose", systemImage: "magnifyingglass")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .navigationTitle(purpose.title(currentBranch: currentBranch))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .sheetMinimumSize(width: 520, height: 440)
        .presentationDetents([.medium, .large])
        .onChange(of: query) { highlighted = nil }
        .onAppear { isFieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(purpose.prompt, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .autocorrectionDisabled()
                .noAutocapitalization()
                .focused($isFieldFocused)
                .onSubmit { chooseHighlighted(inNewTab: false) }
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    chooseHighlighted(inNewTab: true)
                    return .handled
                }
                .onKeyPress(.downArrow) { move(by: 1) }
                .onKeyPress(.upArrow) { move(by: -1) }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var results: [(item: QuickOpenItem, match: FuzzyMatch)] {
        QuickOpenItem.rank(items, query: query)
    }

    /// The highlighted item, or the first while the arrow keys have not moved.
    private func highlightedID(in results: [(item: QuickOpenItem, match: FuzzyMatch)]) -> QuickOpenItem.ID? {
        if let highlighted, results.contains(where: { $0.item.id == highlighted }) { return highlighted }
        return results.first?.item.id
    }

    private func move(by step: Int) -> KeyPress.Result {
        let results = self.results
        guard !results.isEmpty else { return .handled }
        let current = highlightedID(in: results).flatMap { id in results.firstIndex { $0.item.id == id } } ?? 0
        let next = min(max(current + step, 0), results.count - 1)
        highlighted = results[next].item.id
        return .handled
    }

    private typealias Result = (item: QuickOpenItem, match: FuzzyMatch)

    @ViewBuilder
    private func rows(_ results: [Result], highlighted: QuickOpenItem.ID?) -> some View {
        ForEach(results, id: \.item.id) { result in
            Button {
                choose(result.item, false)
            } label: {
                QuickOpenRow(item: result.item, match: result.match)
            }
            .buttonStyle(.plain)
            .listRowBackground(
                result.item.id == highlighted ? RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.2)) : nil
            )
            .id(result.item.id)
        }
    }

    /// The results under their headings, in the order they already have.
    private func sections(of results: [Result]) -> [(section: QuickOpenItem.Section, results: [Result])] {
        var groups: [(section: QuickOpenItem.Section, results: [Result])] = []
        for result in results {
            if groups.last?.section == result.item.section {
                groups[groups.count - 1].results.append(result)
            } else {
                groups.append((result.item.section, [result]))
            }
        }
        return groups
    }

    private func chooseHighlighted(inNewTab: Bool) {
        let results = self.results
        guard let id = highlightedID(in: results), let result = results.first(where: { $0.item.id == id }) else {
            return
        }
        choose(result.item, inNewTab)
    }
}

private struct QuickOpenRow: View {
    var item: QuickOpenItem
    var match: FuzzyMatch

    var body: some View {
        Label {
            HStack(alignment: .firstTextBaseline) {
                Text(highlightedTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: item.systemImage)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    /// The title with the typed characters in bold.
    private var highlightedTitle: AttributedString {
        var text = AttributedString()
        let matched = Set(match.offsets)
        for (offset, character) in item.title.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            text.append(piece)
        }
        return text
    }
}
