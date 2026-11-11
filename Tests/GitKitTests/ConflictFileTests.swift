import Foundation
import GitKit
import Testing

/// A region as either side writes it, lines without their endings, so
/// GitKit's regions and git's conflicted file can be compared.
private enum Region: Equatable, CustomStringConvertible {
    case merged([String])
    case conflict(base: [String], ours: [String], theirs: [String])

    var description: String {
        switch self {
        case .merged(let lines): "merged\(lines)"
        case .conflict(let base, let ours, let theirs): "conflict(base: \(base), ours: \(ours), theirs: \(theirs))"
        }
    }
}

private func regions(of text: MergeText) -> [Region] {
    text.regions.map { region in
        switch region {
        case .merged(let lines): .merged(lines.map(\.withoutLineEnding))
        case .conflict(let conflict):
            .conflict(
                base: conflict.base.map(\.withoutLineEnding),
                ours: conflict.ours.map(\.withoutLineEnding),
                theirs: conflict.theirs.map(\.withoutLineEnding)
            )
        }
    }
}

/// Reads the file git wrote with `merge.conflictStyle=diff3`.
private func regions(ofGitOutput data: Data, markerSize: Int = 7) -> [Region] {
    let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    func isMarker(_ line: String, _ character: Character) -> Bool {
        let marker = String(repeating: character, count: markerSize)
        return line == marker || line.hasPrefix(marker + " ")
    }
    var result: [Region] = []
    var merged: [String] = [], ours: [String] = [], base: [String] = [], theirs: [String] = []
    var state = 0
    for line in lines {
        switch state {
        case 0 where isMarker(line, "<"):
            if !merged.isEmpty { result.append(.merged(merged)) }
            merged = []
            state = 1
        case 0: merged.append(line)
        case 1 where isMarker(line, "|"): state = 2
        case 1: ours.append(line)
        case 2 where isMarker(line, "="): state = 3
        case 2: base.append(line)
        case 3 where isMarker(line, ">"):
            result.append(.conflict(base: base, ours: ours, theirs: theirs))
            ours = []; base = []; theirs = []
            state = 0
        default: theirs.append(line)
        }
    }
    if !merged.isEmpty { result.append(.merged(merged)) }
    return result
}

/// Commits `base` on `main`, then `theirs` on `topic` and `ours` on `main`,
/// and merges `topic` with the command line git in diff3 style. `nil` for a
/// side leaves the file out of that commit.
private func conflictedMerge(
    base: String?, ours: String?, theirs: String?, path: String = "a.txt", attributes: String? = nil
) throws -> Fixture {
    let fixture = try Fixture()
    if let attributes {
        try fixture.commit(".gitattributes", attributes, message: "Attributes")
    } else {
        try fixture.commit("other.txt", "other\n", message: "Start")
    }
    if let base { try fixture.commit(path, base, message: "Base") }
    try fixture.git("checkout", "--quiet", "-b", "topic")
    try change(fixture, path, to: theirs, message: "Theirs")
    try fixture.git("checkout", "--quiet", "main")
    try change(fixture, path, to: ours, message: "Ours")
    _ = try? fixture.git("-c", "merge.conflictStyle=diff3", "merge", "--no-edit", "topic")
    return fixture
}

private func change(_ fixture: Fixture, _ path: String, to text: String?, message: String) throws {
    if let text {
        try fixture.commit(path, text, message: message)
    } else {
        try fixture.git("rm", "--quiet", path)
        try fixture.git("commit", "--quiet", "-m", message)
    }
}

private func mergeText(_ file: ConflictFile) -> MergeText? {
    if case .text(let text) = file.content { text } else { nil }
}

@Suite struct ConflictRegionTests {
    /// Files whose merge conflicts, each as (base, ours, theirs).
    static let fixtures: [(String, String?, String, String)] = [
        ("one conflict in context", "a\nb\nc\nd\ne\n", "a\nb\nours\nd\ne\n", "a\nb\ntheirs\nd\ne\n"),
        (
            "two conflicts and merged changes between",
            "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n",
            "1\nours two\n3\n4\n5\nours six\n7\n8\n9\nours ten\n11\n12\n",
            "1\ntheirs two\n3\n4\ntheirs five\n6\n7\n8\n9\ntheirs ten\nextra\n11\n12\n"
        ),
        ("at the start", "first\nsecond\nthird\n", "ours first\nsecond\nthird\n", "theirs first\nsecond\nthird\n"),
        ("one side deletes lines the other changes", "a\nb\nc\nd\n", "a\nd\n", "a\nB\nC\nd\n"),
        ("both sides added the file", nil, "shared\nours\nshared end\n", "shared\ntheirs\nshared end\n"),
        ("no newline at the end", "x\nbase", "x\nours", "x\ntheirs"),
        ("no newline on one side", "x\nbase\n", "x\nours", "x\ntheirs\n"),
        ("CRLF line endings", "a\r\nb\r\nc\r\n", "a\r\nours\r\nc\r\n", "a\r\ntheirs\r\nc\r\n"),
        ("the same change in both, beside a conflict", "a\nb\nc\nd\n", "A\nb\nours\nd\n", "A\nb\ntheirs\nd\n"),
        ("empty on one side", "a\nb\n", "", "a\nb\nc\n"),
    ]

    @Test(arguments: fixtures.indices)
    func regionsMatchGit(_ position: Int) async throws {
        let (name, base, ours, theirs) = Self.fixtures[position]
        let fixture = try conflictedMerge(base: base, ours: ours, theirs: theirs)
        defer { fixture.remove() }
        #expect(try fixture.git("diff", "--name-only", "--diff-filter=U") == "a.txt", "\(name)")

        let file = try await fixture.open().conflictFile(at: "a.txt")
        #expect(file.hasBase == (base != nil))
        let text = try #require(mergeText(file), "\(name)")
        let git = try Data(contentsOf: fixture.url.appending(path: "a.txt"))
        #expect(regions(of: text) == regions(ofGitOutput: git), "\(name)")
        #expect(!text.conflicts.isEmpty)
    }

    @Test func contentThatLooksLikeMarkersIsNotTakenForThem() async throws {
        let base = "a\n=======\n<<<<<<< not a marker\nb\n"
        let ours = "a\n=======\n<<<<<<< not a marker\nours\n"
        let theirs = "a\n=======\n<<<<<<< not a marker\ntheirs\n"
        // git's markers made longer, so its file can be read back too.
        let fixture = try conflictedMerge(base: base, ours: ours, theirs: theirs, attributes: "* conflict-marker-size=12\n")
        defer { fixture.remove() }
        let text = try #require(mergeText(try await fixture.open().conflictFile(at: "a.txt")))
        let git = try Data(contentsOf: fixture.url.appending(path: "a.txt"))
        #expect(regions(of: text) == regions(ofGitOutput: git, markerSize: 12))
        #expect(regions(of: text) == [
            .merged(["a", "=======", "<<<<<<< not a marker"]), .conflict(base: ["b"], ours: ["ours"], theirs: ["theirs"]),
        ])
    }

    @Test func lineEndingsAreKeptByteForByte() async throws {
        let fixture = try conflictedMerge(base: "a\r\nb\r\nc\r\n", ours: "a\r\nours\r\nc\r\n", theirs: "a\r\ntheirs\r\nc\r\n")
        defer { fixture.remove() }
        let text = try #require(mergeText(try await fixture.open().conflictFile(at: "a.txt")))
        #expect(text.lineEnding == "\r\n")
        #expect(text.merged([0: .ours]) == "a\r\nours\r\nc\r\n")
        #expect(text.merged([0: .oursThenTheirs]) == "a\r\nours\r\ntheirs\r\nc\r\n")
        // Typed text comes with "\n"; the file keeps its own endings.
        #expect(text.merged([0: .edited("one\ntwo")]) == "a\r\none\r\ntwo\r\nc\r\n")
    }

    @Test func aFileWithoutAFinalNewlineKeepsItsEnd() async throws {
        let fixture = try conflictedMerge(base: "x\nbase", ours: "x\nours", theirs: "x\ntheirs")
        defer { fixture.remove() }
        let text = try #require(mergeText(try await fixture.open().conflictFile(at: "a.txt")))
        #expect(text.merged([0: .ours]) == "x\nours")
        #expect(text.merged([0: .theirs]) == "x\ntheirs")
        #expect(text.merged([0: .base]) == "x\nbase")
        // Joined, the first side's last line needs an ending.
        #expect(text.merged([0: .oursThenTheirs]) == "x\nours\ntheirs")
        #expect(text.merged([0: .theirsThenOurs]) == "x\ntheirs\nours")
        #expect(text.merged([0: .edited("typed")]) == "x\ntyped")
        #expect(text.merged([0: .edited("typed\n")]) == "x\ntyped\n")
        #expect(text.merged([:]) == nil)
    }

    @Test func modifyDeleteAndBinaryConflictsAreNotText() async throws {
        let deleted = try conflictedMerge(base: "a\n", ours: nil, theirs: "changed\n")
        defer { deleted.remove() }
        #expect(try await deleted.open().conflictFile(at: "a.txt").content == .deleted(by: .ours))

        let theirsDeleted = try conflictedMerge(base: "a\n", ours: "changed\n", theirs: nil)
        defer { theirsDeleted.remove() }
        #expect(try await theirsDeleted.open().conflictFile(at: "a.txt").content == .deleted(by: .theirs))

        let binary = try conflictedMerge(base: "a\0base\n", ours: "a\0ours\n", theirs: "a\0theirs\n", path: "a.bin")
        defer { binary.remove() }
        #expect(try await binary.open().conflictFile(at: "a.bin").content == .whole)
        await #expect(throws: ConflictError.self) {
            let repository = try binary.open()
            try await repository.saveResolution(of: try await repository.conflictFile(at: "a.bin"), text: "x")
        }
    }
}

@Suite struct ConflictResolutionTests {
    /// Two conflicts with merged lines around and between them.
    static let base = "top\none\nmiddle\ntwo\nbottom\n"
    static let ours = "top\nour one\nmiddle\nour two\nbottom\n"
    static let theirs = "top\ntheir one\nmiddle\ntheir two\nbottom\n"

    static let resolutions: [ConflictResolution] = [
        .ours, .theirs, .base, .oursThenTheirs, .theirsThenOurs, .edited("by hand"), .edited(""),
    ]

    /// What a resolution of conflict `number` (1 or 2) should give.
    static func expected(_ resolution: ConflictResolution, _ number: String) -> String {
        switch resolution {
        case .ours: "our \(number)\n"
        case .theirs: "their \(number)\n"
        case .base: "\(number)\n"
        case .oursThenTheirs: "our \(number)\ntheir \(number)\n"
        case .theirsThenOurs: "their \(number)\nour \(number)\n"
        case .edited(let text): text.isEmpty ? "" : text + "\n"
        }
    }

    @Test func everyCombinationGivesTheExpectedFile() async throws {
        let fixture = try conflictedMerge(base: Self.base, ours: Self.ours, theirs: Self.theirs)
        defer { fixture.remove() }
        let text = try #require(mergeText(try await fixture.open().conflictFile(at: "a.txt")))
        #expect(text.conflicts.count == 2)
        for first in Self.resolutions {
            for second in Self.resolutions {
                let expected = "top\n" + Self.expected(first, "one") + "middle\n" + Self.expected(second, "two") + "bottom\n"
                #expect(text.merged([0: first, 1: second]) == expected, "\(first), \(second)")
            }
        }
        #expect(text.merged([0: .ours]) == nil)
    }

    @Test(arguments: [ConflictResolution.ours, .theirs, .oursThenTheirs, .theirsThenOurs, .edited("by hand")])
    func savingWritesTheFileAndResolvesIt(_ resolution: ConflictResolution) async throws {
        let fixture = try conflictedMerge(base: Self.base, ours: Self.ours, theirs: Self.theirs)
        defer { fixture.remove() }
        let repository = try fixture.open()
        let file = try await repository.conflictFile(at: "a.txt")
        let text = try #require(mergeText(file)?.merged([0: resolution, 1: .theirs]))
        try await repository.saveResolution(of: file, text: text)

        let expected = "top\n" + Self.expected(resolution, "one") + "middle\ntheir two\nbottom\n"
        #expect(try Data(contentsOf: fixture.url.appending(path: "a.txt")) == Data(expected.utf8))
        #expect(try fixture.git("ls-files", "--unmerged") == "")
        #expect(try fixture.git("status", "--porcelain") == "M  a.txt")
        #expect(try fixture.git("show", ":a.txt") == expected.trimmingCharacters(in: .newlines))
        // The merge can now be concluded.
        try fixture.git("commit", "--quiet", "--no-edit")
        #expect(try fixture.parentCounts().first == 2)
    }

    @Test func savingKeepsCRLFAndTheMissingFinalNewline() async throws {
        let fixture = try conflictedMerge(base: "a\r\nbase", ours: "a\r\nours", theirs: "a\r\ntheirs")
        defer { fixture.remove() }
        let repository = try fixture.open()
        let file = try await repository.conflictFile(at: "a.txt")
        let text = try #require(mergeText(file)?.merged([0: .oursThenTheirs]))
        try await repository.saveResolution(of: file, text: text)
        #expect(try Data(contentsOf: fixture.url.appending(path: "a.txt")) == Data("a\r\nours\r\ntheirs".utf8))
        #expect(try fixture.git("ls-files", "--unmerged") == "")
    }

    @Test func savingAppliesTheCheckoutLineEndingConversion() async throws {
        let fixture = try conflictedMerge(
            base: "a\nb\n", ours: "a\nours\n", theirs: "a\ntheirs\n", attributes: "*.txt eol=crlf\n"
        )
        defer { fixture.remove() }
        let repository = try fixture.open()
        let file = try await repository.conflictFile(at: "a.txt")
        let text = try #require(mergeText(file)?.merged([0: .theirs]))
        #expect(text == "a\ntheirs\n")
        try await repository.saveResolution(of: file, text: text)
        #expect(try Data(contentsOf: fixture.url.appending(path: "a.txt")) == Data("a\r\ntheirs\r\n".utf8))
        // The index holds the normalized text, so nothing is left to stage.
        #expect(try fixture.git("status", "--porcelain") == "M  a.txt")
    }

    @Test func aConflictThatChangedIsNotOverwritten() async throws {
        let fixture = try conflictedMerge(base: Self.base, ours: Self.ours, theirs: Self.theirs)
        defer { fixture.remove() }
        let repository = try fixture.open()
        let file = try await repository.conflictFile(at: "a.txt")
        try fixture.git("checkout", "--theirs", "a.txt")
        try fixture.git("add", "a.txt")
        await #expect(throws: ConflictError.changed(path: "a.txt")) {
            try await repository.saveResolution(of: file, text: "lost\n")
        }
        #expect(try fixture.textOfFile("a.txt") == Self.theirs)
    }

    @Test func keepingOrDeletingAModifiedDeletedFile() async throws {
        let keep = try conflictedMerge(base: "a\n", ours: nil, theirs: "changed\n")
        defer { keep.remove() }
        // Keep: the side that has the file; delete: the side that deleted it.
        try await keep.open().resolveConflict(at: "a.txt", using: .theirs)
        #expect(try keep.textOfFile("a.txt") == "changed\n")
        #expect(try keep.git("status", "--porcelain") == "A  a.txt")

        let delete = try conflictedMerge(base: "a\n", ours: nil, theirs: "changed\n")
        defer { delete.remove() }
        try await delete.open().resolveConflict(at: "a.txt", using: .ours)
        #expect(!delete.fileExists("a.txt"))
        #expect(try delete.git("ls-files", "--unmerged") == "")
    }
}

@Suite struct ConflictLabelTests {
    /// `main` and `topic` change a.txt differently since `Base`.
    private func diverged() throws -> (Fixture, topic: String) {
        let fixture = try Fixture()
        try fixture.commit("a.txt", "base\n", message: "Base")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        let topic = try fixture.commit("a.txt", "topic\n", message: "Topic change")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.commit("a.txt", "main\n", message: "Main change")
        return (fixture, topic)
    }

    private func ourAndTheirLines(_ repository: Repository) async throws -> (ours: [String], theirs: [String]) {
        let text = try #require(mergeText(try await repository.conflictFile(at: "a.txt")))
        let conflict = try #require(text.conflicts.first)
        return (conflict.ours.map(\.withoutLineEnding), conflict.theirs.map(\.withoutLineEnding))
    }

    @Test(arguments: [false, true])
    func mergeIsCurrentAgainstIncoming(_ startedByGit: Bool) async throws {
        let (fixture, topic) = try diverged()
        defer { fixture.remove() }
        let repository = try fixture.open()
        if startedByGit {
            _ = try? fixture.git("merge", "--no-edit", "topic")
        } else {
            _ = try await repository.merge("refs/heads/topic", mode: .fastForwardWhenPossible)
        }
        let labels = try await repository.conflictLabels()
        #expect(labels.operation == .merge)
        #expect(labels.ours.role == .current)
        #expect(labels.ours.name == "main")
        #expect(labels.ours.commit?.hex == (try fixture.git("rev-parse", "HEAD")))
        #expect(labels.theirs.role == .incoming)
        #expect(labels.theirs.name == "topic")
        #expect(labels.theirs.commit?.hex == topic)
        #expect(try await ourAndTheirLines(repository) == (["main"], ["topic"]))
    }

    /// Rebasing `topic` onto `main`: git's "ours" is `main`, and "theirs" is
    /// the topic commit being replayed.
    @Test(arguments: [false, true])
    func rebaseSwapsTheSides(_ startedByGit: Bool) async throws {
        let (fixture, topic) = try diverged()
        defer { fixture.remove() }
        try fixture.git("checkout", "--quiet", "topic")
        let repository = try fixture.open()
        if startedByGit {
            _ = try? fixture.git("rebase", "main")
        } else {
            _ = try await repository.rebase(onto: "refs/heads/main")
        }
        let labels = try await repository.conflictLabels()
        #expect(labels.operation == .rebase)
        #expect(labels.ours.role == .onto)
        #expect(labels.ours.name == "main")
        #expect(labels.ours.commit?.hex == (try fixture.git("rev-parse", "main")))
        #expect(labels.theirs.role == .replayed)
        #expect(labels.theirs.name == "topic")
        #expect(labels.theirs.commit?.hex == topic)
        #expect(labels.theirs.summary == "Topic change")
        // And the sides hold what the labels say.
        #expect(try await ourAndTheirLines(repository) == (["main"], ["topic"]))
    }

    @Test(arguments: [false, true])
    func cherryPickIsCurrentAgainstThePickedCommit(_ startedByGit: Bool) async throws {
        let (fixture, topic) = try diverged()
        defer { fixture.remove() }
        let repository = try fixture.open()
        if startedByGit {
            _ = try? fixture.git("cherry-pick", topic)
        } else {
            _ = try await repository.cherryPick([OID(hex: topic)!])
        }
        let labels = try await repository.conflictLabels()
        #expect(labels.operation == .cherryPick)
        #expect(labels.ours.role == .current)
        #expect(labels.ours.name == "main")
        #expect(labels.theirs.role == .picked)
        #expect(labels.theirs.commit?.hex == topic)
        #expect(try await ourAndTheirLines(repository) == (["main"], ["topic"]))
    }

    @Test func revertIsCurrentAgainstTheRevertedCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "One")
        let reverted = try fixture.commit("a.txt", "two\n", message: "Two")
        try fixture.commit("a.txt", "three\n", message: "Three")
        _ = try? fixture.git("revert", "--no-edit", reverted)
        let repository = try fixture.open()
        let labels = try await repository.conflictLabels()
        #expect(labels.operation == .revert)
        #expect(labels.ours.role == .current)
        #expect(labels.theirs.role == .reverted)
        #expect(labels.theirs.commit?.hex == reverted)
        #expect(labels.theirs.summary == "Two")
        // The reverted commit is the base; its parent is "theirs".
        let text = try #require(mergeText(try await repository.conflictFile(at: "a.txt")))
        let conflict = try #require(text.conflicts.first)
        #expect(conflict.base.map(\.withoutLineEnding) == ["two"])
        #expect(conflict.theirs.map(\.withoutLineEnding) == ["one"])
        #expect(conflict.ours.map(\.withoutLineEnding) == ["three"])
    }
}
