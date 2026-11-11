import Foundation
import GitKit
import Testing

/// Stashing some files, or some lines, compared with what git's own stash
/// makes of the same changes; and discarding lines in the cases a
/// selection can make awkward.
@Suite struct PartialStashTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    private static let twenty = (1...20).map { "line \($0)\n" }.joined()

    /// The trees of a stash's working tree and index commits.
    private func stashTrees() throws -> [String] {
        [try fixture.git("rev-parse", "stash@{0}^{tree}"), try fixture.git("rev-parse", "stash@{0}^2^{tree}")]
    }

    /// Staged and unstaged changes to three files, and an untracked one.
    private static func makeChanges(in fixture: Fixture) throws {
        try fixture.commit("a.txt", "a\n", message: "First")
        try fixture.commit("sub/b.txt", "b\n", message: "Second")
        try fixture.commit("c.txt", "c\n", message: "Third")
        try fixture.write("a staged\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("a unstaged\n", to: "a.txt")
        try fixture.write("b changed\n", to: "sub/b.txt")
        try fixture.write("c staged\n", to: "c.txt")
        try fixture.git("add", "c.txt")
        try fixture.write("new\n", to: "new.txt")
    }

    @Test func stashesOnlyTheChosenFilesAsGitDoes() async throws {
        // The same changes in two repositories, one stashed by git, one by Wye.
        let reference = try Fixture()
        defer {
            fixture.remove()
            reference.remove()
        }
        try Self.makeChanges(in: reference)
        try reference.git("stash", "push", "--quiet", "-m", "some", "--", "a.txt", "sub/b.txt")
        try Self.makeChanges(in: fixture)
        let repository = try fixture.open()
        try await repository.saveStash(paths: ["a.txt", "sub/b.txt"], message: "some")

        for revision in ["stash@{0}^{tree}", "stash@{0}^2^{tree}", "stash@{0}^1^{tree}"] {
            let ours = try fixture.git("ls-tree", "-r", revision)
            let theirs = try reference.git("ls-tree", "-r", revision)
            #expect(ours == theirs, "\(revision)")
        }
        let status = try fixture.git("status", "--porcelain")
        #expect(status == (try reference.git("status", "--porcelain")))
        #expect(status == "M  c.txt\n?? new.txt")
        #expect(try fixture.git("stash", "list", "--format=%gs") == "On main: some")
    }

    @Test func refusesPathsWithNothingToStash() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "a\n", message: "First")
        try fixture.write("changed\n", to: "a.txt")
        await #expect(throws: WorkingCopyError.nothingToStash) {
            try await fixture.open().saveStash(paths: ["missing.txt"])
        }
    }

    /// Stashes hunk `index` of `edited` over `original`, and checks the
    /// stash against git's stash of a working tree holding only that hunk.
    private func checkStashingHunk(_ index: Int, original: String, edited: String, path: String = "file.txt") async throws {
        try fixture.commit(path, original, message: "First")
        try fixture.commit("other.txt", "other\n", message: "Second")

        // What git stashes when the working tree has that hunk alone and
        // nothing is staged: its working tree commit has the tree of HEAD
        // with the hunk, its index commit HEAD's tree.
        try fixture.write(edited, to: path)
        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: path))
        try await repository.stage(lines: diff.hunks[index].changedLineIDs, of: diff)
        let expectedTrees = [try fixture.git("write-tree"), try fixture.git("rev-parse", "HEAD^{tree}")]
        try fixture.git("reset", "--quiet")

        try fixture.write("other edited\n", to: "other.txt")
        let current = try #require(try await repository.unstagedDiff(of: path))
        try await repository.saveStash(lines: current.hunks[index].changedLineIDs, of: current, message: "hunk")
        #expect(try stashTrees() == expectedTrees)
        #expect(try fixture.git("stash", "list", "--format=%gs") == "On main: hunk")
        // The other change stays, and so do the file's other hunks.
        #expect(try fixture.workingContent(of: "other.txt") == "other edited\n")
        #expect(try fixture.git("diff", "--cached").isEmpty)
        // The file keeps its other hunk.
        #expect(try fixture.git("diff", "--numstat", "--", path) == "1\t1\t\(path)")
        #expect(try fixture.workingContent(of: path) != edited)
    }

    @Test func stashesOneHunkOfTwo() async throws {
        defer { fixture.remove() }
        try await checkStashingHunk(
            1, original: Self.twenty,
            edited: Self.twenty.replacingOccurrences(of: "line 2\n", with: "two\n")
                .replacingOccurrences(of: "line 18\n", with: "eighteen\n")
        )
    }

    @Test func stashesTheLastHunkOfAFileWithoutANewline() async throws {
        defer { fixture.remove() }
        try await checkStashingHunk(
            1, original: Self.twenty + "last",
            edited: Self.twenty.replacingOccurrences(of: "line 2\n", with: "two\n") + "final"
        )
    }

    @Test func stashesSomeLinesOfAnUntrackedFile() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "a\n", message: "First")
        try fixture.write("one\ntwo\nthree\n", to: "new.txt")
        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "new.txt"))
        try await repository.saveStash(lines: [diff.hunks[0].lines[1].id], of: diff)
        #expect(try fixture.git("show", "stash@{0}:new.txt") == "two")
        #expect(try fixture.workingContent(of: "new.txt") == "one\nthree\n")
    }

    @Test func refusesLinesOfAFileWithStagedChanges() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", Self.twenty, message: "First")
        try fixture.write(Self.twenty.replacingOccurrences(of: "line 2\n", with: "two\n"), to: "file.txt")
        try fixture.git("add", "file.txt")
        try fixture.write(Self.twenty.replacingOccurrences(of: "line 2\n", with: "two\n")
            .replacingOccurrences(of: "line 18\n", with: "eighteen\n"), to: "file.txt")
        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        await #expect(throws: PartialStashError.stagedChanges(path: "file.txt")) {
            try await repository.saveStash(lines: diff.changedLineIDs, of: diff)
        }
        #expect(try fixture.git("stash", "list").isEmpty)
    }

    // MARK: Discarding lines

    @Test func discardsAMixedSelection() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\nb\nc\nd\ne\n", message: "First")
        try fixture.write("a\nB\nc\nD\ne\nf\n", to: "file.txt")
        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        let lines = diff.hunks.flatMap(\.lines)
        // Take back the removal of b and the addition of f; keep the rest.
        let picked = lines.filter { ($0.kind == .deletion && $0.text == "b") || ($0.kind == .addition && $0.text == "f") }
        try await repository.discard(lines: Set(picked.map(\.id)), of: diff)
        #expect(try fixture.workingContent(of: "file.txt") == "a\nb\nB\nc\nD\ne\n")
    }

    @Test func discardsTheLastLineWhenTheFileEndsWithoutANewline() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", Self.twenty + "last", message: "First")
        try fixture.write(Self.twenty.replacingOccurrences(of: "line 2\n", with: "two\n") + "final", to: "file.txt")
        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        #expect(diff.hunks.count == 2)
        try await repository.discard(lines: diff.hunks[1].changedLineIDs, of: diff)
        #expect(try fixture.workingContent(of: "file.txt") == Self.twenty.replacingOccurrences(of: "line 2\n", with: "two\n") + "last")
    }

    @Test func discardsOnlyTheAdditionBeforeAMissingNewline() async throws {
        defer { fixture.remove() }
        try fixture.commit("file.txt", "a\nb", message: "First")
        try fixture.write("a\nb\nc", to: "file.txt")
        let repository = try fixture.open()
        let diff = try #require(try await repository.unstagedDiff(of: "file.txt"))
        let addition = try #require(diff.hunks[0].lines.first { $0.kind == .addition && $0.text == "c" })
        try await repository.discard(lines: [addition.id], of: diff)
        #expect(try fixture.git("diff", "--numstat") == "1\t1\tfile.txt")
        #expect(try fixture.workingContent(of: "file.txt") == "a\nb\n")
    }
}
