import GitKit
import SwiftUI

/// The slice of the commit graph beside one row of a history.
struct GraphCell: View {
    /// The commit's row, or `nil` beside a heading, where lines only pass.
    var row: CommitGraph.Row?
    var passing: [CommitGraph.Line] = []
    /// The graph's width in lanes, the same for every row of a list.
    var width: Int

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
            let dot = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: dot), with: .color(GraphMetrics.color(row.color)))
        }
        .frame(width: Self.width(forLanes: width))
        // Reach a little past the row, so lines meet across any gap between rows.
        .padding(.vertical, -1)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The graph's measurements and colors. Apart from the view, so the canvas's
/// drawing closure, which runs off the main actor, can read them.
enum GraphMetrics {
    static let laneWidth: CGFloat = 12
    /// Beyond this the graph is cut off rather than push the text away.
    static let maximumLanes = 12

    private static let palette: [Color] = [
        .blue, .purple, .orange, .green, .pink, .teal, .indigo, .brown, .cyan, .mint
    ]

    static func color(_ index: Int) -> Color {
        palette[index % palette.count]
    }
}
