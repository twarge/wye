import Foundation
import GitKit
import Testing

/// Staging, unstaging and discarding parts of a file, checked against what
/// git itself then finds in the index and the working tree.
@Suite struct PatchTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    /// Twenty numbered lines, far enough apart for two edits to make two hunks.
    private static let twenty = (1...20).map { "line \($0)\n" }.joined()

    @Test func stagesOneHunkOfTwo() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", Self.twenty, message: "First")
        try fixture.write(Self.twenty.replacingOccurrences(of: "line 2\n", with: "two\n")
            .replacingOccurrences(of: "line 18\n", with: "eighteen\n"), to: "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        #expect(diff.hunks.count == 2)
        try await repository.stage(lines: diff.hunks[1].changedLineIDs, of: diff)

        #expect(try fixture.git("diff", "--cached", "--numstat") == "1\t1\tfile.txt")
        #expect(try fixture.git("diff", "--cached").contains("+eighteen"))
        #expect(try !fixture.git("diff", "--cached").contains("+two"))
        #expect(try fixture.git("diff").contains("+two"))
        #expect(try !fixture.git("diff").contains("+eighteen"))
        #expect(try fixture.git("status", "--porcelain") == "MM file.txt")
    }

    @Test(arguments: [0, 1, 2])
    func stagesOneOfSeveralAddedLines(position: Int) async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\nb\nc\n", message: "First")
        try fixture.write("a\nb\nx\ny\nz\nc\n", to: "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        let additions = diff.hunks[0].lines.filter { $0.kind == .addition }
        #expect(additions.map(\.text) == ["x", "y", "z"])
        try await repository.stage(lines: [additions[position].id], of: diff)

        let added = ["x", "y", "z"][position]
        #expect(try fixture.indexContent(of: "file.txt", is: "a\nb\n\(added)\nc\n"))
        #expect(try fixture.workingContent(of: "file.txt") == "a\nb\nx\ny\nz\nc\n")
    }

    @Test(arguments: [0, 1, 2])
    func stagesOneOfSeveralRemovedLines(position: Int) async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\nx\ny\nz\nb\n", message: "First")
        try fixture.write("a\nb\n", to: "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        let removals = diff.hunks[0].lines.filter { $0.kind == .deletion }
        try await repository.stage(lines: [removals[position].id], of: diff)

        var kept = ["x", "y", "z"]
        kept.remove(at: position)
        #expect(try fixture.indexContent(of: "file.txt", is: "a\n" + kept.map { $0 + "\n" }.joined() + "b\n"))
        #expect(try fixture.git("diff", "--cached", "--numstat") == "0\t1\tfile.txt")
    }

    @Test func stagesPartOfAReplacement() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\nb\nc\nd\ne\n", message: "First")
        // b, c, d become B, C, D.
        try fixture.write("a\nB\nC\nD\ne\n", to: "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        let lines = diff.hunks[0].lines
        #expect(lines.map(\.kind) == [.context, .deletion, .deletion, .deletion, .addition, .addition, .addition, .context])
        // Remove c and add C and D. The old b and d stay, as context, and the
        // additions follow them, as when git's own patch is edited that way.
        let selected: Set = [lines[2].id, lines[5].id, lines[6].id]
        try await repository.stage(lines: selected, of: diff)

        #expect(try fixture.indexContent(of: "file.txt", is: "a\nb\nd\nC\nD\ne\n"))
        #expect(try fixture.git("diff", "--cached", "--numstat") == "2\t1\tfile.txt")
        #expect(try fixture.workingContent(of: "file.txt") == "a\nB\nC\nD\ne\n")
    }

    @Test func stagesLinesInSeveralHunksAtOnce() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", Self.twenty, message: "First")
        // Three lines added near the top move every line of the second hunk.
        var edited = Self.twenty.replacingOccurrences(of: "line 2\n", with: "line 2\nnew 1\nnew 2\nnew 3\n")
        edited = edited.replacingOccurrences(of: "line 18\n", with: "eighteen\n")
        try fixture.write(edited, to: "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        let first = diff.hunks[0].lines.filter { $0.kind == .addition }
        let second = diff.hunks[1].lines.filter(\.isChange)
        try await repository.stage(lines: Set([first[0].id, first[2].id] + second.map(\.id)), of: diff)

        let expected = Self.twenty.replacingOccurrences(of: "line 2\n", with: "line 2\nnew 1\nnew 3\n")
            .replacingOccurrences(of: "line 18\n", with: "eighteen\n")
        #expect(try fixture.indexContent(of: "file.txt", is: expected))
        #expect(try fixture.git("diff", "--numstat") == "1\t0\tfile.txt")
    }

    @Test func keepsAMissingNewlineAtTheEnd() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\nb\n", message: "First")
        try fixture.write("a\nb\nc\nd", to: "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        #expect(diff.hunks[0].lines.last?.kind == .noNewline)
        let additions = diff.hunks[0].lines.filter { $0.kind == .addition }

        // The last line, which has no newline, alone.
        try await repository.stage(lines: [additions[1].id], of: diff)
        #expect(try fixture.indexContent(of: "file.txt", is: "a\nb\nd"))

        // Then the line before it, which now comes before another line.
        let rest = try #require(try await repository.unstagedDiff(of: "file.txt"))
        let addition = try #require(rest.hunks[0].lines.first { $0.kind == .addition })
        try await repository.stage(lines: [addition.id], of: rest)
        #expect(try fixture.indexContent(of: "file.txt", is: "a\nb\nc\nd"))
        #expect(try fixture.git("status", "--porcelain") == "M  file.txt")
    }

    @Test func addsANewlineWhenTheLastLineStopsBeingLast() async throws {
        defer { fixture.remove() }
        // The old last line has no newline; the new file adds lines after it.
        try fixture.commit("file.txt", "a\nb", message: "First")
        try fixture.write("a\nb\nc\n", to: "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        let c = try #require(diff.hunks[0].lines.first { $0.kind == .addition && $0.text == "c" })
        try await repository.stage(lines: [c.id], of: diff)
        #expect(try fixture.indexContent(of: "file.txt", is: "a\nb\nc\n"))
    }

    @Test func removesTheNewlineAtTheEnd() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\nb\nc\n", message: "First")
        try fixture.write("a\nB\nc", to: "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        // Only the change to the last line: from "c\n" to "c".
        let lines = diff.hunks[0].lines
        let lastLine = lines.filter { $0.isChange && $0.text == "c" }.map(\.id)
        #expect(lastLine.count == 2)
        try await repository.stage(lines: Set(lastLine), of: diff)
        #expect(try fixture.indexContent(of: "file.txt", is: "a\nb\nc"))
    }

    @Test func stagesPartOfANewFile() async throws {
        defer { fixture.remove() }
        try fixture.commit("other.txt", "x\n", message: "First")
        try fixture.write("one\ntwo\nthree\n", to: "folder/new file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "folder/new file.txt"))
        #expect(diff.change == .untracked)
        let lines = diff.hunks[0].lines
        try await repository.stage(lines: [lines[0].id, lines[2].id], of: diff)

        #expect(try fixture.indexContent(of: "folder/new file.txt", is: "one\nthree\n"))
        #expect(try fixture.git("status", "--porcelain") == "AM \"folder/new file.txt\"")
    }

    @Test func stagingEveryLineStagesTheWholeFile() async throws {
        defer { fixture.remove() }
        try fixture.commit("other.txt", "x\n", message: "First")
        try fixture.write("one\ntwo\n", to: "new.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "new.txt"))
        try await repository.stage(lines: diff.hunks[0].changedLineIDs, of: diff)
        #expect(try fixture.git("status", "--porcelain") == "A  new.txt")
    }

    @Test func keepsTheFileMode() async throws {
        defer { fixture.remove() }
        try fixture.write("a\nb\nc\nd\ne\nf\ng\nh\n", to: "run.sh")
        try fixture.git("add", "--chmod=+x", "run.sh")
        try fixture.git("commit", "--quiet", "-m", "First")
        try fixture.git("update-index", "--chmod=+x", "run.sh")
        try fixture.write("A\nb\nc\nd\ne\nf\ng\nH\n", to: "run.sh")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "run.sh"))
        try await repository.stage(lines: Set(diff.hunks[0].lines.prefix(2).map(\.id)), of: diff)
        #expect(try fixture.git("ls-files", "--stage", "run.sh").hasPrefix("100755 "))
        #expect(try fixture.indexContent(of: "run.sh", is: "A\nb\nc\nd\ne\nf\ng\nh\n"))
    }

    @Test func unstagesSomeLines() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\nb\nc\nd\ne\n", message: "First")
        try fixture.write("a\nB\nC\nD\ne\n", to: "file.txt")
        try fixture.git("add", "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.stagedDiff(of: "file.txt"))
        let lines = diff.hunks[0].lines
        // Take back the change to c: its removal and C's addition. As with
        // git's own reverse patches, the restored line comes before the run.
        try await repository.unstage(lines: [lines[2].id, lines[5].id], of: diff)

        #expect(try fixture.indexContent(of: "file.txt", is: "a\nc\nB\nD\ne\n"))
        #expect(try fixture.workingContent(of: "file.txt") == "a\nB\nC\nD\ne\n")
        #expect(try fixture.git("diff", "--numstat") == "1\t1\tfile.txt")
    }

    @Test func unstagesPartOfANewFile() async throws {
        defer { fixture.remove() }
        try fixture.commit("other.txt", "x\n", message: "First")
        try fixture.write("one\ntwo\nthree", to: "new.txt")
        try fixture.git("add", "new.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.stagedDiff(of: "new.txt"))
        let lines = diff.hunks[0].lines.filter(\.isChange)
        try await repository.unstage(lines: [lines[1].id], of: diff)
        #expect(try fixture.indexContent(of: "new.txt", is: "one\nthree"))

        let rest = try #require(try await repository.stagedDiff(of: "new.txt"))
        try await repository.unstage(lines: rest.changedLineIDs, of: rest)
        #expect(try fixture.git("status", "--porcelain") == "?? new.txt")
    }

    @Test func unstagesBeforeTheFirstCommit() async throws {
        defer { fixture.remove() }
        try fixture.write("one\ntwo\n", to: "new.txt")
        try fixture.git("add", "new.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.stagedDiff(of: "new.txt"))
        try await repository.unstage(lines: [diff.hunks[0].lines[0].id], of: diff)
        #expect(try fixture.indexContent(of: "new.txt", is: "two\n"))
    }

    @Test func discardsSomeLinesInTheWorkingTree() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", Self.twenty, message: "First")
        try fixture.write(Self.twenty.replacingOccurrences(of: "line 2\n", with: "two\n")
            .replacingOccurrences(of: "line 18\n", with: "eighteen\n"), to: "file.txt")
        try fixture.git("add", "file.txt")
        try fixture.write(Self.twenty.replacingOccurrences(of: "line 2\n", with: "TWO\n")
            .replacingOccurrences(of: "line 18\n", with: "EIGHTEEN\n"), to: "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        try await repository.discard(lines: diff.hunks[0].changedLineIDs, of: diff)

        // The working tree goes back to the staged version for that hunk only.
        #expect(try fixture.workingContent(of: "file.txt") == Self.twenty
            .replacingOccurrences(of: "line 2\n", with: "two\n")
            .replacingOccurrences(of: "line 18\n", with: "EIGHTEEN\n"))
        #expect(try fixture.git("diff", "--cached", "--numstat") == "2\t2\tfile.txt")
    }

    @Test func keepsCarriageReturns() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\r\nb\r\n", message: "First")
        try fixture.write("a\r\nB\r\nc\r\n", to: "file.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        let c = try #require(diff.hunks[0].lines.first { $0.kind == .addition && $0.text == "c" })
        try await repository.stage(lines: [c.id], of: diff)
        #expect(try fixture.indexContent(of: "file.txt", is: "a\r\nb\r\nc\r\n"))
    }

    @Test func discardsSomeLinesOfAnUntrackedFile() async throws {
        defer { fixture.remove() }
        try fixture.commit("other.txt", "x\n", message: "First")
        try fixture.write("one\ntwo\nthree\n", to: "new.txt")

        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "new.txt"))
        try await repository.discard(lines: [diff.hunks[0].lines[1].id], of: diff, untracked: .delete)
        #expect(try fixture.workingContent(of: "new.txt") == "one\nthree\n")
        #expect(try fixture.git("status", "--porcelain") == "?? new.txt")
    }

    @Test func refusesADiffThatIsOutOfDate() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\nb\n", message: "First")
        try fixture.write("a\nB\n", to: "file.txt")
        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        try fixture.write("a\nchanged again\n", to: "file.txt")

        await #expect(throws: WorkingCopyError.diffChanged(path: "file.txt")) {
            try await repository.stage(lines: diff.changedLineIDs, of: diff)
        }
        await #expect(throws: WorkingCopyError.nothingSelected) {
            let current = try #require(try await repository.unstagedDiff(of: "file.txt"))
            try await repository.stage(lines: [current.hunks[0].lines[0].id], of: current)
        }
        #expect(try fixture.git("diff", "--cached").isEmpty)
    }
}

extension Fixture {
    /// Whether the index holds exactly `text` for `path`, byte for byte,
    /// which compares trailing newlines too.
    func indexContent(of path: String, is text: String) throws -> Bool {
        let expected = url.appendingPathExtension("expected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: expected) }
        try Data(text.utf8).write(to: expected)
        return try git("hash-object", expected.path) == git("rev-parse", ":" + path)
    }

    func workingContent(of path: String) throws -> String {
        try String(contentsOf: url.appending(path: path), encoding: .utf8)
    }
}
