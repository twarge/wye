import GitKit
import SwiftUI

extension View {
    /// Lets the diffs in this scroll view be searched with a find bar.
    /// Applied to the `ScrollView` whose rows are ``FileDiffView``s.
    func findInDiffs(_ diffs: [FindableDiff]) -> some View {
        modifier(FindableModifier(source: diffs) { $0.flatMap(\.lines) })
    }

    /// Lets a file's lines in this scroll view be searched with a find bar.
    /// Each row carries `FindRow(group: "", line: index)` as its ID and
    /// draws the marks ``FindModel/marks(for:)`` gives it.
    func findInLines(_ lines: [String]) -> some View {
        modifier(FindableModifier(source: lines) { lines in
            lines.enumerated().map { FindLine(row: FindRow(group: "", line: $0.offset), text: $0.element) }
        })
    }
}

/// Puts a find bar over the scroll view it is applied to, searches as the
/// query changes, and scrolls to the current match. The Edit menu's Find
/// commands reach it while focus is anywhere in the view.
private struct FindableModifier<Source: Equatable & Sendable>: ViewModifier {
    var source: Source
    var lines: @Sendable (Source) -> [FindLine]

    @State private var find = FindModel()

    private struct SearchKey: Equatable {
        var source: Source
        var query: String
        var isCaseSensitive: Bool
        var isPresented: Bool
    }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .environment(find)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if find.isPresented {
                        FindBar(find: find)
                    }
                }
                // Clicking the diff gives it focus, which is what puts its
                // find bar behind ⌘F rather than the history's search.
                .focusable()
                .focusEffectDisabled()
                .focusedValue(\.findModel, find)
                .toolbar {
                    if Platform.showsFindButton {
                        ToolbarItem {
                            Button("Find", systemImage: "magnifyingglass") { find.present() }
                        }
                    }
                }
                .task(id: SearchKey(source: source, query: find.query, isCaseSensitive: find.isCaseSensitive, isPresented: find.isPresented)) {
                    guard find.isPresented, !find.query.isEmpty else {
                        find.set([])
                        return
                    }
                    let source = source, query = find.query, isCaseSensitive = find.isCaseSensitive, lines = lines
                    // Off the main actor: a long diff takes a moment to search.
                    let matches = await Task.detached(priority: .userInitiated) {
                        FindModel.matches(of: query, in: lines(source), caseSensitive: isCaseSensitive)
                    }.value
                    guard !Task.isCancelled else { return }
                    find.set(matches)
                }
                .onChange(of: find.scrollRequests) {
                    guard let match = find.currentMatch else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(match.row, anchor: .center)
                    }
                }
        }
    }
}

/// The bar: the query, how many matches, case sensitivity, and stepping
/// between matches.
private struct FindBar: View {
    @Bindable var find: FindModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $find.query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .noAutocapitalization()
                .focused($isFieldFocused)
                .onSubmit { find.next() }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.previous()
                    return .handled
                }
                .onKeyPress(.escape) {
                    find.dismiss()
                    return .handled
                }
            Text(find.status)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Toggle(isOn: $find.isCaseSensitive) {
                Text("Aa")
                    .font(.callout.weight(.semibold))
            }
            .toggleStyle(.button)
            .help("Match upper and lower case exactly")
            .accessibilityLabel("Match Case")
            ControlGroup {
                Button("Previous", systemImage: "chevron.up") { find.previous() }
                    .help("Show the previous match (⇧⌘G)")
                Button("Next", systemImage: "chevron.down") { find.next() }
                    .help("Show the next match (⌘G)")
            }
            .fixedSize()
            .disabled(find.matches.isEmpty)
            Button("Done") { find.dismiss() }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: find.focusRequests, initial: true) {
            isFieldFocused = true
        }
    }
}

/// The Edit menu's Find commands for the diff or file that has focus,
/// before Find in History.
struct FindMenuItems: View {
    var find: FindModel?

    var body: some View {
        Button("Find…") { find?.present() }
            .keyboardShortcut(find == nil ? nil : KeyboardShortcut("f"))
            .disabled(find == nil)
        Button("Find Next") { find?.next() }
            .keyboardShortcut("g")
            .disabled(find?.matches.isEmpty ?? true)
        Button("Find Previous") { find?.previous() }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(find?.matches.isEmpty ?? true)
    }
}
