import Foundation
import GitKit
import Testing
@testable import WyeUI

private func commit(_ character: Character, _ summary: String) -> Commit {
    let id = OID(hex: String(repeating: character, count: 40))!
    let author = Signature(name: "A", email: "a@example.com", date: Date(timeIntervalSince1970: 0))
    return Commit(id: id, parentIDs: [], treeID: id, author: author, committer: author, summary: summary, body: "")
}

private func review(
    branch: String? = "main", upstream: String? = "origin/main", hasRemote: Bool = true,
    entries: [StatusEntry] = [], commits: [Commit] = [], ahead: Int = 0, behind: Int = 0,
    lastModified: Date? = nil
) -> RepositoryReview {
    RepositoryReview(
        id: UUID(), name: "Wye", branch: branch, upstream: upstream, hasRemote: hasRemote,
        entries: entries, commits: commits, ahead: ahead, behind: behind, lastModified: lastModified
    )
}

private func modified(_ path: String) -> StatusEntry {
    StatusEntry(path: path, staged: nil, unstaged: .modified)
}

private func staged(_ path: String, _ change: FileChange = .modified) -> StatusEntry {
    StatusEntry(path: path, staged: change, unstaged: nil)
}

@Suite struct ReviewSummaryTests {
    @Test func countsFilesStagedAndUnpushedCommits() {
        let item = review(
            entries: [staged("a.swift"), StatusEntry(path: "b.swift", staged: .modified, unstaged: .modified), modified("c.swift")],
            ahead: 1
        )
        #expect(item.summary == "3 files changed · 2 staged · 1 unpushed commit")
    }

    @Test func saysOneFileAndManyCommits() {
        #expect(review(entries: [modified("a")]).summary == "1 file changed")
        #expect(review(ahead: 4).summary == "4 unpushed commits")
        #expect(review(entries: [modified("a"), modified("b")], ahead: 2).summary == "2 files changed · 2 unpushed commits")
    }

    @Test func untrackedFilesCountAsChanged() {
        let item = review(entries: [StatusEntry(path: "new.txt", staged: nil, unstaged: .untracked), staged("a", .added)])
        #expect(item.summary == "2 files changed · 1 staged")
    }

    @Test func saysConflictsBeforeWhatIsStaged() {
        let item = review(entries: [
            StatusEntry(path: "a", staged: nil, unstaged: .conflicted),
            StatusEntry(path: "b", staged: nil, unstaged: .conflicted),
            staged("c")
        ])
        #expect(item.summary == "3 files changed · 2 conflicted · 1 staged")
    }

    @Test func saysABranchIsNotPublished() {
        #expect(review(upstream: nil).summary == "branch not published")
        #expect(review(upstream: nil, entries: [modified("a")]).summary == "1 file changed · branch not published")
        // With nowhere to publish to, it is only the files.
        #expect(review(upstream: nil, hasRemote: false, entries: [modified("a")]).summary == "1 file changed")
    }

    @Test func leavesOutCommitsToPull() {
        #expect(review(entries: [modified("a")], behind: 3).summary == "1 file changed")
        #expect(review().summary == "Committed and pushed")
    }
}

@Suite struct ReviewCaptionTests {
    @Test func promptsWithNothingWhenThereIsNothingToDescribe() {
        #expect(ReviewCaption.prompt(for: review(), excerpt: "") == nil)
        // Unpushed commits that were not read say nothing either.
        #expect(ReviewCaption.prompt(for: review(ahead: 2), excerpt: "") == nil)
    }

    @Test func promptListsFilesCommitsAndTheExcerpt() throws {
        let item = review(
            branch: "dark-mode",
            entries: [
                staged("Settings.swift"), StatusEntry(path: "Theme.swift", staged: nil, unstaged: .untracked),
                StatusEntry(path: "New.swift", originalPath: "Old.swift", staged: .renamed, unstaged: nil)
            ],
            commits: [commit("a", "Add a theme picker")], ahead: 1
        )
        let prompt = try #require(ReviewCaption.prompt(for: item, excerpt: "diff --git a/Settings.swift b/Settings.swift\n+dark"))
        #expect(prompt.contains("Branch: dark-mode"))
        #expect(prompt.contains("- Settings.swift (modified, staged)"))
        #expect(prompt.contains("- Theme.swift (new)"))
        #expect(prompt.contains("- New.swift (renamed from Old.swift, staged)"))
        #expect(prompt.contains("- Add a theme picker"))
        #expect(prompt.contains("+dark"))
    }

    @Test func promptIsBoundedHoweverMuchChanged() throws {
        let entries = (0..<500).map { modified("Sources/File\($0).swift") }
        let commits = (0..<40).map { _ in commit("b", String(repeating: "x", count: 500)) }
        let excerpt = String(repeating: "+line\n", count: 10_000)
        let item = review(entries: entries, commits: commits, ahead: 40)
        let prompt = try #require(ReviewCaption.prompt(for: item, excerpt: excerpt))
        #expect(prompt.contains("- Sources/File29.swift"))
        #expect(!prompt.contains("- Sources/File30.swift"))
        #expect(prompt.contains("- and 470 more"))
        #expect(prompt.count < 6_000)
    }

    @Test func excerptsOnlySmallFilesStillOnDisk() {
        let sizes = ["small": 10, "large": ReviewCaption.excerptFileSize + 1]
        let entries = [
            modified("small"), modified("large"), modified("dir"),
            StatusEntry(path: "gone", staged: nil, unstaged: .deleted)
        ] + (0..<20).map { modified("f\($0)") }
        let paths = ReviewCaption.excerptPaths(of: entries) { path in
            sizes[path] ?? (path.hasPrefix("f") ? 100 : nil)
        }
        #expect(paths.first == "small")
        #expect(!paths.contains("large"))
        #expect(!paths.contains("dir"))
        #expect(!paths.contains("gone"))
        #expect(paths.count == ReviewCaption.excerptFileLimit)
    }

    @Test func excerptKeepsToItsBudget() {
        let patch = (0..<20).map { "diff --git a/f\($0) b/f\($0)\n" + String(repeating: "+text\n", count: 500) }.joined()
        #expect(ReviewCaption.excerpt(of: patch).count <= ReviewCaption.excerptBudget)
    }

    @Test func readsTheAnswerAsOneLine() {
        #expect(ReviewCaption.parse("Adds dark mode to the settings window") == "Adds dark mode to the settings window")
        #expect(ReviewCaption.parse("  \"Fixes the crash\"  \n\nMore text") == "Fixes the crash")
        #expect(ReviewCaption.parse("Summary: Renames the model") == "Renames the model")
        #expect(ReviewCaption.parse("```\nUpdates the README\n```") == "Updates the README")
        #expect(ReviewCaption.parse("  \n ") == nil)
        #expect(ReviewCaption.parse("“”") == nil)
        let long = ReviewCaption.parse(String(repeating: "word ", count: 100))
        #expect(long?.count == 160)
        #expect(long?.hasSuffix("…") == true)
    }

    @MainActor
    @Test func keyChangesWhenTheChangesDo() {
        let item = review(entries: [modified("a")], lastModified: Date(timeIntervalSince1970: 1))
        var edited = item
        edited.lastModified = Date(timeIntervalSince1970: 2)
        var restaged = item
        restaged.entries = [StatusEntry(path: "a", staged: .modified, unstaged: nil)]
        var pushed = item
        pushed.commits = [commit("c", "Commit")]
        #expect(ReviewCaptions.Key(item) == ReviewCaptions.Key(item))
        #expect(ReviewCaptions.Key(item) != ReviewCaptions.Key(edited))
        #expect(ReviewCaptions.Key(item) != ReviewCaptions.Key(restaged))
        #expect(ReviewCaptions.Key(item) != ReviewCaptions.Key(pushed))
    }
}
