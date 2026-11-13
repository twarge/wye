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
    lastModified: Date? = nil, otherBranches: [BranchToPull] = [], reviewRequests: [ReviewRequest] = [],
    hasMoreReviewRequests: Bool = false
) -> RepositoryReview {
    RepositoryReview(
        id: UUID(), name: "Wye", branch: branch, upstream: upstream, hasRemote: hasRemote,
        entries: entries, commits: commits, ahead: ahead, behind: behind, lastModified: lastModified,
        otherBranches: otherBranches, reviewRequests: reviewRequests, hasMoreReviewRequests: hasMoreReviewRequests
    )
}

private func toPull(_ name: String, _ behind: Int) -> BranchToPull {
    BranchToPull(name: name, upstream: "origin/" + name, behind: behind)
}

private func request(
    _ number: Int, _ title: String = "Add login", kind: HostingKind = .github, author: String? = "mona"
) -> ReviewRequest {
    ReviewRequest(repository: "example.com/octo/project", kind: kind, number: number, title: title, author: author)
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

    @Test func saysCommitsToPullAfterTheWorkHere() {
        #expect(review(behind: 1).summary == "1 commit to pull")
        #expect(review(entries: [modified("a")], behind: 3).summary == "1 file changed · 3 commits to pull")
        #expect(review(ahead: 2, behind: 3).summary == "2 unpushed commits · 3 commits to pull")
        #expect(review().summary == "Committed and pushed")
    }

    @Test func saysAnotherBranchByItsNameAndSeveralByTheirNumber() {
        #expect(review(otherBranches: [toPull("release", 1)]).summary == "1 commit to pull on release")
        #expect(review(otherBranches: [toPull("release", 4)]).summary == "4 commits to pull on release")
        let several = review(otherBranches: [toPull("release", 5), toPull("topic", 1)])
        #expect(several.summary == "6 commits to pull on 2 other branches")
        // After the checked-out branch's own.
        #expect(
            review(ahead: 1, behind: 2, otherBranches: [toPull("release", 3)]).summary
                == "1 unpushed commit · 2 commits to pull · 3 commits to pull on release"
        )
    }

    @Test func saysInFullWhatThereIsToPullAndOnWhichBranch() {
        #expect(review(behind: 1).pullSentence == "1 commit to pull from origin/main")
        #expect(review(behind: 12).pullSentence == "12 commits to pull from origin/main")
        #expect(review(ahead: 3).pullSentence == nil)
        #expect(toPull("release", 2).pullSentence == "“release” has 2 commits to pull from origin/release")
        #expect(toPull("old", 1).pullSentence == "“old” has 1 commit to pull from origin/old")
    }

    @Test func saysPullRequestsToReviewInTheServicesWords() {
        #expect(review(reviewRequests: [request(12)]).summary == "1 pull request to review")
        #expect(review(reviewRequests: [request(12), request(13)]).summary == "2 pull requests to review")
        #expect(review(reviewRequests: [request(7, kind: .gitlab)]).summary == "1 merge request to review")
        #expect(
            review(entries: [modified("a")], behind: 1, reviewRequests: [request(12)]).summary
                == "1 file changed · 1 commit to pull · 1 pull request to review"
        )
        // More on the service than were read.
        #expect(review(reviewRequests: [request(12)], hasMoreReviewRequests: true).summary == "1+ pull requests to review")
    }

    @Test func listsARepositoryForEachReasonAndNotWithoutOne() {
        #expect(!review().needsAttention)
        #expect(review(entries: [modified("a")]).needsAttention)
        #expect(review(ahead: 1).needsAttention)
        #expect(review(upstream: nil).needsAttention)
        // Commits to pull are not work, but they are a reason to look.
        #expect(!review(behind: 2).hasWork)
        #expect(review(behind: 2).needsAttention)
        #expect(review(otherBranches: [toPull("release", 1)]).needsAttention)
        #expect(review(reviewRequests: [request(12)]).needsAttention)
        // Nowhere to publish to, nothing to pull, nobody asking.
        #expect(!review(upstream: nil, hasRemote: false).needsAttention)
        #expect(!review(branch: nil, upstream: nil).needsAttention)
    }

    @Test func findsOtherBranchesAndPullRequests() {
        let item = review(
            otherBranches: [toPull("release/2.0", 1)], reviewRequests: [request(12, "Fix the parser", author: "hubot")]
        )
        #expect(item.matches("release"))
        #expect(item.matches("parser"))
        #expect(item.matches("#12"))
        #expect(item.matches(" hubot "))
        #expect(!item.matches("login"))
    }

    @Test func totalsEveryReason() {
        let totals = ReviewTotals([
            review(entries: [modified("a"), modified("b")], ahead: 1, behind: 2),
            review(otherBranches: [toPull("release", 4)]),
            review(reviewRequests: [request(12), request(13)]),
            review()
        ])
        #expect(totals.repositories == 3)
        #expect(totals.files == 2)
        #expect(totals.commits == 1)
        #expect(totals.toPull == 6)
        #expect(totals.reviewRequests == 2)
        #expect(
            totals.sentence
                == "2 uncommitted files, 1 unpushed commit, 6 commits to pull and 2 pull requests to review in 3 repositories"
        )
        #expect(ReviewTotals([review(behind: 1)]).sentence == "1 commit to pull in 1 repository")
        #expect(
            ReviewTotals([review(behind: 1, reviewRequests: [request(7, kind: .gitlab)])]).sentence
                == "1 commit to pull and 1 merge request to review in 1 repository"
        )
        // Pull requests and merge requests together go by the commoner name.
        #expect(
            ReviewTotals([review(reviewRequests: [request(7, kind: .gitlab)]), review(reviewRequests: [request(12)])]).sentence
                == "2 pull requests to review in 2 repositories"
        )
    }
}

@Suite struct BranchToPullTests {
    private let oid: OID

    init() throws {
        oid = try #require(OID(hex: String(repeating: "a", count: 40)))
    }

    private func branch(_ name: String, isHead: Bool = false, ahead: Int? = nil, behind: Int = 0) -> Branch {
        Branch(
            id: "refs/heads/" + name, name: name, target: oid, isHead: isHead,
            upstream: ahead.map { Branch.Upstream(name: "origin/" + name, ahead: $0, behind: behind) }
        )
    }

    @Test func listsOtherBranchesWhoseUpstreamsAreAhead() {
        let snapshot = RepositorySnapshot(
            head: .branch(name: "refs/heads/main", target: oid),
            branches: [
                // Unpushed commits on another branch are not a reason to list a repository.
                branch("fix", ahead: 2), branch("level", ahead: 0), branch("local"),
                // The checked-out branch's commits are the row's own.
                branch("main", isHead: true, ahead: 5, behind: 5),
                branch("release", ahead: 0, behind: 3), branch("topic", ahead: 1, behind: 1)
            ]
        )
        #expect(BranchToPull.others(in: snapshot) == [
            BranchToPull(name: "release", upstream: "origin/release", behind: 3),
            BranchToPull(name: "topic", upstream: "origin/topic", behind: 1)
        ])
    }

    @Test func aDetachedHeadLeavesEveryBranchAnother() {
        let snapshot = RepositorySnapshot(head: .detached(oid), branches: [branch("main", ahead: 0, behind: 1)])
        #expect(BranchToPull.others(in: snapshot).map(\.name) == ["main"])
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
