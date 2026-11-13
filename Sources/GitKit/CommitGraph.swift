/// Lays a history out as a graph: which lane each commit sits in, and the
/// lines that join it to its children above and its parents below.
///
/// Feed it commits in the order the history lists them, children before
/// parents. It keeps only the lanes that are still open, so a history can be
/// laid out page by page.
///
/// Given a main line, it keeps that line straight in the first lane, as
/// other clients do: every other line starts to its right, branching off it
/// and joining it again, so an old branch or tag is a short stub beside it
/// rather than a lane that pushes it aside.
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
    /// The main line's next commit, until the line ends: the first lane is
    /// kept for it, even before it starts, so nothing else takes it.
    private var mainNext: OID?
    private static let mainColor = 0

    /// - Parameter mainLine: The commit whose line of first parents stays
    ///   in the first lane, in the first color (see
    ///   `Repository.mainLine(of:options:)`). Without one, each line takes
    ///   the first free lane.
    public init(mainLine: OID? = nil) {
        mainNext = mainLine
        nextColor = mainLine == nil ? 0 : Self.mainColor + 1
    }

    /// The lanes open below the last row, which the next row's lines continue.
    public var openLines: [Line] {
        lanes.enumerated().compactMap { index, lane in
            lane.map { Line(lane: index, color: $0.color) }
        }
    }

    /// Adds the next commit of the history and returns its row.
    public mutating func append(_ id: OID, parents: [OID]) -> Row {
        let lane: Int
        let color: Int
        if id == mainNext {
            // Whatever else arrives here joins it.
            lane = 0
            color = Self.mainColor
            mainNext = parents.first
        } else {
            // Where several lines arrive, the leftmost carries on.
            let arriving = lanes.indices.first { lanes[$0]?.next == id }
            lane = arriving ?? freeLane()
            color = arriving.flatMap { lanes[$0]?.color } ?? takeColor()
        }

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
            } else if parent == mainNext {
                // The main line, not drawn yet: it starts here.
                place(Lane(next: parent, color: Self.mainColor), at: 0)
                row.outgoing.append(Line(lane: 0, color: Self.mainColor))
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

    /// The leftmost lane that is free, past the main line's while it runs.
    private func freeLane() -> Int {
        let first = mainNext == nil ? 0 : 1
        return lanes.indices.first { $0 >= first && lanes[$0] == nil } ?? max(lanes.count, first)
    }

    private mutating func place(_ lane: Lane, at index: Int) {
        while lanes.count <= index {
            lanes.append(nil)
        }
        lanes[index] = lane
    }

    private mutating func takeColor() -> Int {
        defer { nextColor += 1 }
        return nextColor
    }
}
