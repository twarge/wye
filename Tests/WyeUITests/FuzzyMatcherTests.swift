import Testing
@testable import WyeUI

@Suite struct FuzzyMatcherTests {
    @Test func needsEveryCharacterInOrder() {
        #expect(FuzzyMatcher.match("mn", in: "main") != nil)
        #expect(FuzzyMatcher.match("nm", in: "main") == nil)
        #expect(FuzzyMatcher.match("mainx", in: "main") == nil)
        #expect(FuzzyMatcher.match("MAIN", in: "main")?.offsets == [0, 1, 2, 3])
        #expect(FuzzyMatcher.match("", in: "main") == FuzzyMatch(score: 0, offsets: []))
        // Spaces in the query are ignored, accents in either side too.
        #expect(FuzzyMatcher.match("fe ma", in: "feature/main") != nil)
        #expect(FuzzyMatcher.match("resume", in: "résumé") != nil)
    }

    @Test func prefersWordStartsAndRuns() {
        // "fm" picks the start of each word, not the first m it could.
        #expect(FuzzyMatcher.match("fm", in: "feature/main")?.offsets == [0, 8])
        #expect(FuzzyMatcher.match("log", in: "feature/login")?.offsets == [8, 9, 10])
        #expect(FuzzyMatcher.match("rw", in: "RepositoryWatcher")?.offsets == [0, 10])
    }

    @Test func ranksBetterMatchesHigher() {
        func score(_ query: String, _ name: String) -> Int { FuzzyMatcher.match(query, in: name)?.score ?? .min }
        // Equal here: quick open's ranking puts the shorter name first.
        #expect(score("main", "main") == score("main", "maintenance-window"))
        #expect(score("main", "origin/main") > score("main", "my-awesome-index-node"))
        #expect(score("fl", "feature/login") > score("fl", "fooled"))
        #expect(score("v1", "v1.0") > score("v1", "very-old-1"))
    }
}

@Suite struct QuickOpenRankingTests {
    private func item(_ name: String) -> QuickOpenItem {
        QuickOpenItem(target: .branch("refs/heads/" + name), title: name, detail: "Branch")
    }

    @Test func putsTheBestAndShortestFirst() {
        let items = ["maintenance-window", "feature/main", "main", "docs", "my-awesome-index-node"].map(item)
        #expect(QuickOpenItem.rank(items, query: "main").map(\.item.title)
            == ["main", "maintenance-window", "feature/main", "my-awesome-index-node"])
        // With nothing typed, everything, in the order given.
        #expect(QuickOpenItem.rank(items, query: "").map(\.item.title) == items.map(\.title))
        #expect(QuickOpenItem.rank(items, query: "zz").isEmpty)
    }
}
