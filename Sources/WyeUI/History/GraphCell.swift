import GitKit
import SwiftUI

/// The slice of the commit graph beside one row of a history.
struct GraphCell: View {
    /// The commit's row, or `nil` beside a heading, where lines only pass.
    var row: CommitGraph.Row?
    var passing: [CommitGraph.Line] = []
    /// The graph's width in lanes, the same for every row of a list.
    var width: Int
    /// For a merge: its dot is a disclosure control for the branch it merged.
    var fold: Fold?
    var toggleFold: () -> Void = {}

    enum Fold: Hashable, Sendable {
        case open
        case folded
    }

    static func width(forLanes lanes: Int) -> CGFloat {
        CGFloat(min(lanes, GraphMetrics.maximumLanes)) * GraphMetrics.laneWidth
    }

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            func x(_ lane: Int) -> CGFloat {
                CGFloat(lane) * GraphMetrics.laneWidth + GraphMetrics.laneWidth / 2
            }
            func stroke(from start: CGPoint, to end: CGPoint, color: Int) {
                var path = Path()
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let bend = (start.y + end.y) / 2
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: bend),
                        control2: CGPoint(x: end.x, y: bend)
                    )
                }
                context.stroke(path, with: .color(GraphMetrics.color(color)), lineWidth: 1.5)
            }

            for line in (row?.passing ?? []) + passing {
                stroke(from: CGPoint(x: x(line.lane), y: 0), to: CGPoint(x: x(line.lane), y: size.height), color: line.color)
            }
            guard let row else { return }
            let center = CGPoint(x: x(row.lane), y: middle)
            for line in row.incoming {
                stroke(from: CGPoint(x: x(line.lane), y: 0), to: center, color: line.color)
            }
            for line in row.outgoing {
                stroke(from: center, to: CGPoint(x: x(line.lane), y: size.height), color: line.color)
            }
            let color = GraphMetrics.color(row.color)
            guard let fold else {
                let dot = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(color))
                return
            }
            // A merge: a ring with a disclosure chevron in it, pointing
            // down while its branch shows and right when folded away.
            let radius = GraphMetrics.foldRadius
            let ring = Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
            ))
            context.blendMode = .normal
            context.fill(ring, with: .style(.background))
            context.stroke(ring, with: .color(color), lineWidth: 1.5)
            var chevron = Path()
            let reach: CGFloat = 2.6, depth: CGFloat = 1.4
            switch fold {
            case .open:
                chevron.move(to: CGPoint(x: center.x - reach, y: center.y - depth))
                chevron.addLine(to: CGPoint(x: center.x, y: center.y + depth))
                chevron.addLine(to: CGPoint(x: center.x + reach, y: center.y - depth))
            case .folded:
                chevron.move(to: CGPoint(x: center.x - depth, y: center.y - reach))
                chevron.addLine(to: CGPoint(x: center.x + depth, y: center.y))
                chevron.addLine(to: CGPoint(x: center.x - depth, y: center.y + reach))
            }
            context.stroke(chevron, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: Self.width(forLanes: width))
        .overlay(alignment: .leading) {
            if let row, let fold, row.lane < GraphMetrics.maximumLanes {
                Button(fold == .open ? "Hide Merged Commits" : "Show Merged Commits", action: toggleFold)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: GraphMetrics.laneWidth + 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .opacity(0.02)
                    .offset(x: CGFloat(row.lane) * GraphMetrics.laneWidth - 4)
                    .help(fold == .open ? "Hide the commits this merge brought in" : "Show the commits this merge brought in")
            }
        }
        // Reach a little past the row, so lines meet across any gap between rows.
        .padding(.vertical, -1)
        .clipped()
        .accessibilityHidden(fold == nil)
    }
}

/// The graph's measurements and colors. Apart from the view, so the canvas's
/// drawing closure, which runs off the main actor, can read them.
enum GraphMetrics {
    static let laneWidth: CGFloat = 12
    /// The ring a merge's disclosure chevron sits in.
    static let foldRadius: CGFloat = 5.5
    /// Beyond this the graph is cut off rather than push the text away.
    static let maximumLanes = 12

    private static let palette: [Color] = [
        .blue, .purple, .orange, .green, .pink, .teal, .indigo, .brown, .cyan, .mint
    ]

    static func color(_ index: Int) -> Color {
        palette[index % palette.count]
    }
}
