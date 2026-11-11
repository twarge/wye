import GitKit
import Testing
@testable import WyeUI

/// "top", conflict one, "middle", conflict two, "bottom".
private let text = MergeText(
    regions: [
        .merged(["top\n"]),
        .conflict(TextConflict(base: ["one\n"], ours: ["our one\n"], theirs: ["their one\n"], isAtEnd: false)),
        .merged(["middle\n"]),
        .conflict(TextConflict(base: ["two\n"], ours: ["our two\n"], theirs: ["their two\n"], isAtEnd: false)),
        .merged(["bottom\n"]),
    ],
    lineEnding: "\n"
)

@Suite struct TextResolutionTests {
    @Test func countsAndResultFollowTheChoices() {
        var session = TextResolution(text: text)
        #expect(session.count == 2)
        #expect(session.remaining == 2)
        #expect(session.result == nil)

        session.resolveCurrent(.theirs)
        #expect(session.remaining == 1)
        // Moves on to the conflict still open.
        #expect(session.current == 1)
        session.resolveCurrent(.oursThenTheirs)
        #expect(session.isComplete)
        #expect(session.result == "top\ntheir one\nmiddle\nour two\ntheir two\nbottom\n")

        session.clearCurrent()
        #expect(session.remaining == 1)
        #expect(session.result == nil)
    }

    @Test func navigationStaysWithinTheConflicts() {
        var session = TextResolution(text: text)
        #expect(!session.canGoBack)
        session.previous()
        #expect(session.current == 0)
        session.next()
        #expect(session.current == 1)
        #expect(!session.canGoForward)
        session.next()
        #expect(session.current == 1)
        session.go(to: 0)
        #expect(session.current == 0)
    }

    @Test func resolvingTheLastOpenConflictGoesBackToAnEarlierOne() {
        var session = TextResolution(text: text)
        session.go(to: 1)
        session.resolveCurrent(.ours)
        #expect(session.current == 0)
    }

    @Test func editingStartsFromTheCurrentChoice() {
        var session = TextResolution(text: text)
        #expect(session.draftForCurrent == "our one")
        session.resolveCurrent(.theirsThenOurs)
        session.go(to: 0)
        #expect(session.draftForCurrent == "their one\nour one")
        session.resolveCurrent(.edited("typed\nby hand"))
        #expect(session.text.merged([0: .edited("typed\nby hand"), 1: .base]) == "top\ntyped\nby hand\nmiddle\ntwo\nbottom\n")
    }

    @Test func theResultShowsOpenConflictsBetweenMarkers() {
        var session = TextResolution(text: text)
        session.resolveCurrent(.ours)
        let segments = session.segments(oursLabel: "main", theirsLabel: "topic")
        #expect(segments.map(\.kind) == [.merged, .resolved(conflict: 0), .merged, .open(conflict: 1), .merged])
        #expect(segments[1].text == "our one")
        #expect(segments[3].text == "<<<<<<< main\nour two\n=======\ntheir two\n>>>>>>> topic")
    }
}

@Suite struct ConflictLabelTitleTests {
    @Test func rebaseNamesTheSidesForWhatTheyAre() {
        let onto = ConflictSideLabel(role: .onto, name: "main", commit: nil, summary: nil)
        let replayed = ConflictSideLabel(role: .replayed, name: "topic", commit: nil, summary: "Fix")
        #expect(onto.title == "Upstream")
        #expect(onto.heading == "Upstream · main")
        #expect(replayed.title == "Your Commit")
        #expect(replayed.explanation.contains("“topic”"))
    }

    @Test func mergePreviewWording() {
        let merge = MergePreviewSection.Operation.merge("refs/heads/topic", mode: .fastForwardWhenPossible)
        #expect(MergePreviewText.headline(MergePreview(.fastForward), operation: merge) == "Fast-forward")
        #expect(MergePreviewText.headline(MergePreview(.clean), operation: merge) == "Merges cleanly")
        #expect(MergePreviewText.headline(MergePreview(.conflicts(["a", "b", "c"])), operation: merge) == "Conflicts in 3 files")
        #expect(MergePreviewText.headline(MergePreview(.conflicts(["a"])), operation: merge) == "Conflicts in 1 file")
        let always = MergePreviewSection.Operation.merge("refs/heads/topic", mode: .alwaysCommit)
        #expect(MergePreviewText.headline(MergePreview(.fastForward), operation: always).hasPrefix("Merges cleanly"))
        let rebase = MergePreviewSection.Operation.rebase(onto: "refs/heads/main")
        #expect(MergePreviewText.headline(MergePreview(.clean, commitCount: 2), operation: rebase) == "Replays 2 commits cleanly")
        #expect(MergePreviewText.headline(
            MergePreview(.conflicts(["a"]), commitCount: 3, stoppingStep: 2), operation: rebase
        ) == "Conflicts in 1 file at commit 2 of 3")
    }
}
