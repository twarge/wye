import SwiftUI

/// How wide a history's columns are, in points. The message takes what is
/// left. Kept on each device rather than synced: screens differ.
struct HistoryColumnWidths: Hashable {
    var hash: CGFloat = 60
    var author: CGFloat = 120
    var date: CGFloat = 64

    /// The place for the mark of a commit's checks, which has no title
    /// and is not resized.
    static let checks: CGFloat = 16

    /// Between one column and the next, in the header and in every row.
    static let spacing: CGFloat = 8
    static let range: ClosedRange<CGFloat> = 30...480
}

/// Names a history's columns above its rows and resizes them by the
/// dividers between them: the hash by the one at its right, the author and
/// date by the one at their left, as the message gives or takes the
/// difference. Right-click it for which columns show.
struct HistoryColumnHeader: View {
    var columns: HistoryColumns
    /// The graph's width and the gap after it, as the rows lead with.
    var leading: CGFloat

    @Bindable private var preferences = HistoryPreferences.shared

    var body: some View {
        let spacing = HistoryColumnWidths.spacing
        HStack(spacing: spacing) {
            if columns.hash {
                title("Hash")
                    .frame(width: preferences.columnWidths.hash, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        ColumnDivider(width: $preferences.columnWidths.hash, widensRightward: true)
                            .offset(x: ColumnDivider.hitWidth / 2 + spacing / 2)
                    }
            }
            title("Message")
                .frame(maxWidth: .infinity, alignment: .leading)
            if columns.checks {
                Color.clear
                    .frame(width: HistoryColumnWidths.checks, height: 1)
            }
            if columns.author {
                title("Author")
                    .frame(width: preferences.columnWidths.author, alignment: .leading)
                    .overlay(alignment: .leading) {
                        ColumnDivider(width: $preferences.columnWidths.author, widensRightward: false)
                            .offset(x: -ColumnDivider.hitWidth / 2 - spacing / 2)
                    }
            }
            if columns.date {
                title("Date")
                    .frame(width: preferences.columnWidths.date, alignment: .leading)
                    .overlay(alignment: .leading) {
                        ColumnDivider(width: $preferences.columnWidths.date, widensRightward: false)
                            .offset(x: -ColumnDivider.hitWidth / 2 - spacing / 2)
                    }
            }
        }
        .padding(.leading, leading)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            HistoryRowOptions()
            HistoryGroupingPicker()
            Divider()
            Button("Reset Column Widths") { preferences.columnWidths = HistoryColumnWidths() }
                .disabled(preferences.columnWidths == HistoryColumnWidths())
        }
    }

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// A line between two column titles, dragged to resize the column it
/// belongs to.
private struct ColumnDivider: View {
    @Binding var width: CGFloat
    /// Whether dragging right widens the column: true at its right edge.
    var widensRightward: Bool

    /// The width at the start of a drag.
    @State private var startWidth: CGFloat?

    static let hitWidth: CGFloat = 9

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 13)
            .frame(width: Self.hitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // In the window's coordinates: the divider moves as it is dragged.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = startWidth ?? width
                    startWidth = start
                    let change = widensRightward ? drag.translation.width : -drag.translation.width
                    width = min(max(start + change, HistoryColumnWidths.range.lowerBound),
                                HistoryColumnWidths.range.upperBound)
                }
                .onEnded { _ in startWidth = nil })
            #if os(macOS)
            .pointerStyle(.columnResize)
            #endif
            .accessibilityHidden(true)
    }
}
