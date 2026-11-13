#if os(macOS)
import SwiftUI

/// How a repository window's list and the detail open on its right share
/// the room they have. The list keeps the width the user gave it and the
/// detail takes the rest, so a change in the window's width goes to the
/// detail.
///
/// Too narrow for that, the detail gives way first, down to its narrowest;
/// then the list does, down to its own, taking its width back as the room
/// returns. Narrower still, which the window's own minimum does not allow,
/// the list keeps its narrowest and the detail has what is left.
struct DetailSplitWidths: Equatable {
    /// Room for a hash, a summary and a date: the detail or a narrow window
    /// take no more than this from the list.
    static let listMinimum: CGFloat = 380
    /// The narrowest the detail gets beside the list.
    static let detailMinimum: CGFloat = 320
    /// The line between the two.
    static let divider: CGFloat = 1
    /// The list's width until the user drags the divider. In a new window,
    /// its sidebar at its narrowest, that leaves the detail the 560 points
    /// it has always opened with.
    static let defaultListWidth: CGFloat = 490
    /// Where the list's width is kept, for every window.
    static let listWidthKey = "window.listWidth"

    var list: CGFloat
    var detail: CGFloat

    /// The widths in `available` points for a list that is to be
    /// `preferred` wide.
    init(preferred: CGFloat, available: CGFloat) {
        // A width read back from the preferences may be anything.
        let wanted = preferred.isFinite ? preferred : Self.defaultListWidth
        let most = available - Self.divider - Self.detailMinimum
        list = max(Self.listMinimum, min(wanted, most))
        detail = max(0, available - Self.divider - list)
    }

    /// The narrowest the list is with the detail closed, or the two are
    /// side by side: what the window can be narrowed to, the sidebar aside.
    static func minimumWidth(showsDetail: Bool) -> CGFloat {
        showsDetail ? listMinimum + divider + detailMinimum : listMinimum
    }
}

/// A repository window's list and, while it is open, the detail on its
/// right, with a divider to drag between them.
///
/// SwiftUI's inspector, which the detail used to be, keeps its own width
/// and leaves a change in the window's to the list beside it. Here it is
/// the list that keeps its width, as `DetailSplitWidths` shares it out,
/// which also spares the list a layout on every frame of a window resize.
/// Only a drag of the divider changes the list's width, which is kept when
/// the drag ends.
struct DetailSplit<Leading: View, Detail: View>: View {
    var showsDetail: Bool
    /// The width the list is to have beside the detail.
    @Binding var listWidth: Double
    @ViewBuilder var list: Leading
    @ViewBuilder var detail: Detail

    @Environment(\.layoutDirection) private var layoutDirection
    /// The divider's drag, while there is one.
    @State private var drag: Drag?
    @State private var measure = SplitMeasure()

    /// How wide a strip takes the pointer for the divider: its line and a
    /// little of either side, which leaves the list's scroller its own.
    private static var handleWidth: CGFloat { 7 }

    private struct Drag {
        /// The list's width when the drag began.
        var start: CGFloat
        /// Its width now.
        var width: CGFloat
    }

    var body: some View {
        DetailSplitLayout(listWidth: drag?.width ?? CGFloat(listWidth)) {
            list
                .layoutValue(key: DetailSplitRole.self, value: .list)
            if showsDetail {
                detail
                    .layoutValue(key: DetailSplitRole.self, value: .detail)
                handle
                    .layoutValue(key: DetailSplitRole.self, value: .handle)
            }
        }
        // For the drag only: nothing is laid out again when it changes.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measure.width = $0 }
    }

    /// The line between the list and the detail, dragged to resize the list.
    private var handle: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: DetailSplitWidths.divider)
            .frame(width: Self.handleWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // In the window's coordinates: the divider moves as it is dragged.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = drag?.start
                        ?? DetailSplitWidths(preferred: listWidth, available: measure.width).list
                    let change = layoutDirection == .rightToLeft ? -value.translation.width : value.translation.width
                    // Kept within what fits, so that the divider turns back
                    // as soon as the pointer does.
                    let width = DetailSplitWidths(preferred: start + change, available: measure.width).list
                    drag = Drag(start: start, width: width)
                }
                .onEnded { _ in
                    if let drag { listWidth = drag.width }
                    drag = nil
                })
            .pointerStyle(.columnResize)
            .accessibilityHidden(true)
    }
}

extension FocusedValues {
    /// Whether the detail is open on the right of the repository window in
    /// front, for the menu bar to open and close it.
    @Entry var detailVisibility: Binding<Bool>?
}

/// View ▸ Show Details and Hide Details, for the detail on the right of a
/// repository window, with the shortcut the system gives an inspector's
/// command, ⌃⌘I.
struct DetailCommands: Commands {
    @FocusedBinding(\.detailVisibility) private var showsDetail

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button(showsDetail == true ? "Hide Details" : "Show Details") {
                if let showsDetail { self.showsDetail = !showsDetail }
            }
            .keyboardShortcut("i", modifiers: [.command, .control])
            .disabled(showsDetail == nil)
        }
    }
}

/// The split's width as last laid out, for a drag of the divider to stay
/// within. Not observed: it changes on every frame of a window resize,
/// when nothing needs to be built again for it.
@MainActor
private final class SplitMeasure {
    var width: CGFloat = 0
}

/// What a view inside the split is, for the layout to place it.
private struct DetailSplitRole: LayoutValueKey {
    enum Role {
        case list, detail, handle
    }

    static let defaultValue = Role.list
}

/// Places the list at its width with the detail filling the rest and the
/// divider's handle over the line between them; the list alone fills it all.
private struct DetailSplitLayout: Layout {
    /// The width the list is to have beside the detail.
    var listWidth: CGFloat

    /// The height asked for when none is proposed. The views are not asked
    /// for theirs: a list measures every one of its rows to answer.
    private static var idealHeight: CGFloat { 480 }
    /// The detail's width when none is proposed, as its inspector's was.
    private static var idealDetailWidth: CGFloat { 560 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let showsDetail = subviews.contains { $0[DetailSplitRole.self] == .detail }
        let ideal = showsDetail ? listWidth + DetailSplitWidths.divider + Self.idealDetailWidth : listWidth
        let width = max(DetailSplitWidths.minimumWidth(showsDetail: showsDetail), proposal.width ?? ideal)
        guard let proposed = proposal.height else {
            return CGSize(width: width, height: Self.idealHeight)
        }
        guard proposed.isFinite, width.isFinite else {
            return CGSize(width: width, height: proposed)
        }
        // As tall as proposed, or as the taller of the two needs to be.
        let widths = DetailSplitWidths(preferred: listWidth, available: width)
        let heights = subviews.map { subview in
            let share: CGFloat = switch subview[DetailSplitRole.self] {
            case .list: showsDetail ? widths.list : width
            case .detail: widths.detail
            case .handle: 0
            }
            return subview.sizeThatFits(ProposedViewSize(width: share, height: proposed)).height
        }
        return CGSize(width: width, height: max(proposed, heights.max() ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let showsDetail = subviews.contains { $0[DetailSplitRole.self] == .detail }
        let widths = DetailSplitWidths(preferred: listWidth, available: bounds.width)
        let line = bounds.minX + widths.list
        for subview in subviews {
            switch subview[DetailSplitRole.self] {
            case .list:
                let width = showsDetail ? widths.list : bounds.width
                place(subview, in: CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height))
            case .detail:
                place(subview, in: CGRect(x: line + DetailSplitWidths.divider, y: bounds.minY,
                                          width: widths.detail, height: bounds.height))
            case .handle:
                subview.place(at: CGPoint(x: line + DetailSplitWidths.divider / 2, y: bounds.minY), anchor: .top,
                              proposal: ProposedViewSize(width: nil, height: bounds.height))
            }
        }
    }

    /// Places a view in its part of the split: filling it, as a list does,
    /// or in its middle when the view is smaller, as a split view's column
    /// has a note that nothing is selected. One too large for it starts at
    /// its top left.
    private func place(_ subview: LayoutSubview, in frame: CGRect) {
        let proposal = ProposedViewSize(frame.size)
        let size = subview.sizeThatFits(proposal)
        let origin = CGPoint(x: frame.minX + max(0, (frame.width - size.width) / 2),
                             y: frame.minY + max(0, (frame.height - size.height) / 2))
        subview.place(at: origin, proposal: proposal)
    }
}
#endif
