/// Lays a history out as a graph: which lane each commit sits in, and the
/// lines that join it to its children above and its parents below.
///
/// Feed it commits in the order the history lists them, children before
/// parents. It keeps only the lanes that are still open, so a history can be
/// laid out page by page.
public struct CommitGraph: Sendable {
    /// One row of the graph, for one commit.
    public struct Row: Hashable, Sendable {
        /// The lane the commit's dot sits in.
        public var lane: Int
        public var color: Int
        /// Lanes that end at this commit, arriving from the row above.
        public var incoming: [Line]
        /// Lanes that start at this commit, leaving to the row below.
        public var outgoing: [Line]
        /// Lanes that run straight past this commit.
        public var passing: [Line]

        /// How many lanes wide the row is.
        public var width: Int {
            (incoming + outgoing + passing).map(\.lane).reduce(lane, max) + 1
        }
    }

    public struct Line: Hashable, Sendable {
        public var lane: Int
        public var color: Int

        public init(lane: Int, color: Int) {
            self.lane = lane
            self.color = color
        }
    }

    private struct Lane {
        /// The commit this lane is waiting to reach.
        var next: OID
        var color: Int
    }

    private var lanes: [Lane?] = []
    private var nextColor = 0

    public init() {}

    /// The lanes open below the last row, which the next row's lines continue.
    public var openLines: [Line] {
        lanes.enumerated().compactMap { index, lane in
            lane.map { Line(lane: index, color: $0.color) }
        }
    }

    /// Adds the next commit of the history and returns its row.
    public mutating func append(_ id: OID, parents: [OID]) -> Row {
        let arriving = lanes.indices.filter { lanes[$0]?.next == id }
        let lane = arriving.first ?? freeLane()
        let color = arriving.first.flatMap { lanes[$0]?.color } ?? takeColor()

        var row = Row(lane: lane, color: color, incoming: [], outgoing: [], passing: [])
        for index in lanes.indices {
            guard let open = lanes[index] else { continue }
            let line = Line(lane: index, color: open.color)
            if open.next == id {
                row.incoming.append(line)
                lanes[index] = nil
            } else {
                row.passing.append(line)
            }
        }

        for (position, parent) in parents.enumerated() {
            if position == 0 {
                // The first parent continues the commit's own lane, in its
                // own color, even when another line already leads to that
                // parent: a branch keeps its lane and color all the way
                // down to the commit it started from, and the line it left
                // keeps its own.
                place(Lane(next: parent, color: color), at: lane)
                row.outgoing.append(Line(lane: lane, color: color))
            } else if let existing = lanes.firstIndex(where: { $0?.next == parent }) {
                // A merged line that is already drawn: join its lane.
                row.outgoing.append(Line(lane: existing, color: lanes[existing]!.color))
            } else {
                let target = freeLane()
                let branchColor = takeColor()
                place(Lane(next: parent, color: branchColor), at: target)
                row.outgoing.append(Line(lane: target, color: branchColor))
            }
        }

        // Drop closed lanes off the end so the graph narrows again.
        while case .some(.none) = lanes.last {
            lanes.removeLast()
        }
        return row
    }

    private func freeLane() -> Int {
        lanes.firstIndex { $0 == nil } ?? lanes.count
    }

    private mutating func place(_ lane: Lane, at index: Int) {
        if index == lanes.count {
            lanes.append(lane)
        } else {
            lanes[index] = lane
        }
    }

    private mutating func takeColor() -> Int {
        defer { nextColor += 1 }
        return nextColor
    }
}
