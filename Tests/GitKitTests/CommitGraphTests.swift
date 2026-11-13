import GitKit
import Testing

@Suite struct CommitGraphTests {
    private func id(_ number: Int) -> OID {
        OID(hex: String(repeating: "0", count: 39) + String(number, radix: 16))!
    }

    @Test func aLinearHistoryStaysInOneLane() {
        var graph = CommitGraph()
        let rows = [
            graph.append(id(3), parents: [id(2)]),
            graph.append(id(2), parents: [id(1)]),
            graph.append(id(1), parents: [])
        ]
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.map(\.width) == [1, 1, 1])
        #expect(Set(rows.map(\.color)).count == 1)
        #expect(rows[0].incoming.isEmpty)
        #expect(rows[1].incoming.map(\.lane) == [0])
        #expect(rows[2].outgoing.isEmpty)
        #expect(graph.openLines.isEmpty)
    }

    @Test func aMergeOpensALaneThatClosesWhereTheBranchesMeet() {
        // 5 merges 4 (main) and 3 (topic); both descend from 2.
        var graph = CommitGraph()
        let merge = graph.append(id(5), parents: [id(4), id(3)])
        #expect(merge.lane == 0)
        #expect(merge.outgoing.map(\.lane) == [0, 1])
        #expect(merge.outgoing[0].color != merge.outgoing[1].color)

        let main = graph.append(id(4), parents: [id(2)])
        #expect(main.lane == 0)
        #expect(main.passing.map(\.lane) == [1])

        let topic = graph.append(id(3), parents: [id(2)])
        #expect(topic.lane == 1)
        #expect(topic.color == merge.outgoing[1].color)
        // It keeps its own lane and color down to where it branched off.
        #expect(topic.outgoing == [CommitGraph.Line(lane: 1, color: topic.color)])
        #expect(topic.passing.map(\.lane) == [0])

        // The base sits on the line it belongs to; the branch curves in,
        // still in its own color.
        let base = graph.append(id(2), parents: [id(1)])
        #expect(base.lane == 0)
        #expect(base.color == main.color)
        #expect(base.incoming == [
            CommitGraph.Line(lane: 0, color: main.color), CommitGraph.Line(lane: 1, color: topic.color)
        ])
        #expect(base.outgoing.map(\.lane) == [0])
        #expect(graph.openLines.map(\.lane) == [0])
    }

    @Test func unrelatedBranchTipsGetTheirOwnLanes() {
        var graph = CommitGraph()
        let first = graph.append(id(9), parents: [id(1)])
        let second = graph.append(id(8), parents: [id(1)])
        #expect(first.lane == 0)
        #expect(second.lane == 1)
        #expect(second.outgoing.map(\.lane) == [1])
        #expect(first.color != second.color)
        #expect(graph.openLines.map(\.lane) == [0, 1])

        let base = graph.append(id(1), parents: [])
        #expect(base.lane == 0)
        #expect(base.incoming.map(\.lane) == [0, 1])
        #expect(graph.openLines.isEmpty)
    }

    @Test func theMainLineKeepsTheFirstLaneFromItsStart() {
        // 9 is a newer branch off 5; 8 is the main line, through 7 to 5.
        var plain = CommitGraph()
        let order: [(OID, [OID])] = [
            (id(9), [id(5)]), (id(8), [id(7)]), (id(7), [id(5)]), (id(5), [id(4)])
        ]
        // Without a main line, the newer branch takes the first lane and
        // the main line moves over to it where they meet.
        #expect(order.map { plain.append($0.0, parents: $0.1).lane } == [0, 1, 1, 0])

        var graph = CommitGraph(mainLine: id(8))
        let rows = order.map { graph.append($0.0, parents: $0.1) }
        #expect(rows.map(\.lane) == [1, 0, 0, 0])
        #expect(rows[1].incoming.isEmpty)
        #expect(rows[1].color == rows[3].color)
        #expect(rows[0].color != rows[1].color)
        // The branch curves into the main line where it left it.
        #expect(rows[3].incoming.map(\.lane) == [0, 1])
        #expect(graph.openLines.map(\.lane) == [0])
    }

    @Test func aStubOffTheMainLineSitsBesideIt() {
        // 4 is an old commit off 2, listed between 3 and 2 by its date.
        var graph = CommitGraph(mainLine: id(3))
        let main = graph.append(id(3), parents: [id(2)])
        let stub = graph.append(id(4), parents: [id(2)])
        let base = graph.append(id(2), parents: [id(1)])
        #expect([main.lane, stub.lane, base.lane] == [0, 1, 0])
        #expect(stub.passing.map(\.lane) == [0])
        #expect(base.incoming.map(\.lane) == [0, 1])
        #expect(base.width == 2)
        // Once it has rejoined, the graph is one lane wide again.
        let root = graph.append(id(1), parents: [])
        #expect(root.lane == 0)
        #expect(root.width == 1)
        #expect(graph.openLines.isEmpty)
    }

    @Test func aMergeIntoTheMainLineBeforeItStartsDrawsItFromThere() {
        // 9, on another line, merged the main line's first commit, 5.
        var graph = CommitGraph(mainLine: id(5))
        let merge = graph.append(id(9), parents: [id(8), id(5)])
        #expect(merge.lane == 1)
        #expect(merge.outgoing.map(\.lane) == [1, 0])
        let main = graph.append(id(5), parents: [id(4)])
        #expect(main.lane == 0)
        #expect(main.incoming.map(\.lane) == [0])
        #expect(main.passing.map(\.lane) == [1])
    }
}
