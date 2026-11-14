import Foundation
import GitKit
import Testing
import WyeShared
@testable import WyeUI

private let oidA = OID(hex: String(repeating: "a", count: 40))!
private let oidB = OID(hex: String(repeating: "b", count: 40))!

private func commit(_ id: OID, _ summary: String, parents: [OID] = []) -> Commit {
    let author = Signature(name: "A", email: "a@example.com", date: Date(timeIntervalSince1970: 0))
    return Commit(id: id, parentIDs: parents, treeID: id, author: author, committer: author, summary: summary, body: "")
}

@Suite struct PullAllReportTests {
    private func snapshot(
        head: Head, state: RepositoryState = .clean, upstream: Branch.Upstream? = nil, remotes: [Remote] = []
    ) -> RepositorySnapshot {
        let branch = Branch(id: "refs/heads/main", name: "main", target: oidA, isHead: true, upstream: upstream)
        return RepositorySnapshot(head: head, state: state, branches: [branch], remotes: remotes)
    }

    private let origin = [Remote(name: "origin", url: "https://example.com/r.git", branches: [])]
    private let tracking = Branch.Upstream(name: "origin/main", ahead: 0, behind: 2)

    @Test func saysWhyARepositoryHasNothingToPull() {
        let onMain = Head.branch(name: "refs/heads/main", target: oidA)
        #expect(PullAllReport.skipReason(for: snapshot(head: onMain, upstream: tracking, remotes: origin)) == nil)
        #expect(PullAllReport.skipReason(for: snapshot(head: onMain, upstream: tracking)) == "No remote.")
        #expect(PullAllReport.skipReason(for: snapshot(head: .detached(oidA), upstream: tracking, remotes: origin))
            == "No branch is checked out.")
        #expect(PullAllReport.skipReason(for: snapshot(head: onMain, remotes: origin))
            == "The branch tracks no remote branch.")
        #expect(PullAllReport.skipReason(for: snapshot(head: onMain, state: .merging, upstream: tracking, remotes: origin))
            == "An operation is waiting to be finished.")
    }

    private func result(_ name: String, _ outcome: PullAllResult.Outcome) -> PullAllResult {
        PullAllResult(id: UUID(), name: name, outcome: outcome)
    }

    @Test func summarisesTheRun() {
        #expect(PullAllReport.summary(of: []) == "Nothing to pull.")
        let results = [
            result("a", .updated("x")), result("b", .upToDate), result("c", .upToDate),
            result("d", .skipped("No remote.")), result("e", .failed("x")), result("f", .needsAttention("x")),
            result("g", .waiting)
        ]
        #expect(PullAllReport.summary(of: results) == "1 updated, 2 up to date, 1 skipped, 1 need attention, 1 failed")
    }

    @Test func listsProblemsFirst() {
        let sorted = PullAllReport.sorted([
            result("zeta", .upToDate), result("beta", .updated("x")), result("alpha", .skipped("x")),
            result("gamma", .failed("x")), result("delta", .needsAttention("x")), result("eta", .failed("x"))
        ])
        #expect(sorted.map(\.name) == ["eta", "gamma", "delta", "beta", "alpha", "zeta"])
        #expect(sorted.prefix(3).map(\.isProblem) == [true, true, true])
        #expect(!result("x", .skipped("x")).isProblem)
        #expect(!result("x", .pulling).isFinished)
    }

    @MainActor @Test func aRowDoesNotRepeatItsRepositorysName() {
        #expect(PullAllModel.detail("alpha: unsupported URL protocol", name: "alpha") == "Unsupported URL protocol")
        #expect(PullAllModel.detail("Local changes in alpha are in the way.", name: "alpha")
            == "Local changes in alpha are in the way.")
        #expect(PullAllModel.detail("alpha: ", name: "alpha") == "alpha: ")
    }

    @Test func saysPullAllAloud() {
        #expect(IntentPhrasing.pulledAll([]) == "There are no repositories in Wye to pull.")
        let text = IntentPhrasing.pulledAll([
            result("a", .updated("x")), result("b", .failed("No route to host.")), result("c", .failed("y"))
        ])
        #expect(text == "1 updated, 2 failed. b: No route to host. 1 more need a look in Wye.")
    }
}

@Suite struct ReviewTests {
    private func review(
        _ name: String, branch: String? = "main", upstream: String? = "origin/main", hasRemote: Bool = true,
        files: [String] = [], commits: [Commit] = [], ahead: Int = 0
    ) -> RepositoryReview {
        RepositoryReview(
            id: UUID(), name: name, branch: branch, upstream: upstream, hasRemote: hasRemote,
            entries: files.map { StatusEntry(path: $0, staged: nil, unstaged: .modified) },
            commits: commits, ahead: ahead, behind: 0
        )
    }

    @Test func knowsWhatCountsAsWork() {
        #expect(!review("clean").hasWork)
        #expect(review("dirty", files: ["a"]).hasWork)
        #expect(review("ahead", ahead: 2).hasWork)
        // A branch never published is work only where there is somewhere to publish it.
        #expect(review("unpublished", upstream: nil).hasWork)
        #expect(!review("local", upstream: nil, hasRemote: false).hasWork)
        #expect(!review("detached", branch: nil, upstream: nil).hasWork)
    }

    @Test func totalsOnlyRepositoriesWithWork() {
        let totals = ReviewTotals([
            review("a", files: ["x", "y"]), review("b", ahead: 3), review("c"), review("d", files: ["z"], ahead: 1)
        ])
        #expect(totals.repositories == 3)
        #expect(totals.files == 3)
        #expect(totals.commits == 4)
        #expect(totals.sentence == "3 uncommitted files and 4 unpushed commits in 3 repositories")
        #expect(ReviewTotals([review("c")]).sentence == "Everything is committed, pushed and up to date.")
        #expect(ReviewTotals([review("a", files: ["x"])]).sentence == "1 uncommitted file in 1 repository")
        #expect(ReviewTotals([review("u", upstream: nil)]).sentence == "Unpublished branches in 1 repository")
    }

    @Test func searchesNamesBranchesFilesAndCommits() {
        let item = review("Horizontal", branch: "topic", files: ["Sources/View.swift"], commits: [commit(oidA, "Fix the crash")])
        #expect(item.matches(""))
        #expect(item.matches("  "))
        #expect(item.matches("horiz"))
        #expect(item.matches("TOPIC"))
        #expect(item.matches("view.swift"))
        #expect(item.matches("crash"))
        #expect(!item.matches("nothing"))
    }
}

@Suite struct DragTests {
    @Test func namesAPatchOfSeveralCommitsAfterTheOldest() {
        let newest = commit(oidA, "Add the thing"), oldest = commit(oidB, "Fix a bug")
        #expect(CommitDrag.fileName(for: [newest]) == Repository.patchFileName(for: newest))
        let name = CommitDrag.fileName(for: [newest, oldest])
        #expect(name == Repository.patchFileName(for: oldest).dropLast(".patch".count) + "-and-1-more.patch")
        #expect(CommitDrag.fileName(for: []) == "commits.patch")
    }

    @Test func aFileFromACommitIsNamedForIt() {
        let hash = oidA.abbreviated()
        #expect(FileDrag.fileName(for: "Sources/main.swift", commit: nil) == "main.swift")
        #expect(FileDrag.fileName(for: "Sources/main.swift", commit: oidA) == "main-\(hash).swift")
        #expect(FileDrag.fileName(for: "Makefile", commit: oidA) == "Makefile-\(hash)")
        #expect(FileDrag.fileName(for: ".gitignore", commit: oidA) == ".gitignore-\(hash)")
        #expect(FileDrag.fileName(for: "a/archive.tar.gz", commit: oidA) == "archive.tar-\(hash).gz")
    }

    @Test func tellsAPatchFromFilesToAdd() {
        let repository = URL(filePath: "/r/app", directoryHint: .isDirectory)
        let patch = URL(filePath: "/tmp/0001-fix.patch"), photo = URL(filePath: "/tmp/photo.png")
        #expect(WorkingCopyDrop.make([patch], repository: repository) == .patch(patch))
        #expect(WorkingCopyDrop.make([URL(filePath: "/tmp/change.DIFF")], repository: repository)
            == .patch(URL(filePath: "/tmp/change.DIFF")))
        // Several files are files, patches among them.
        #expect(WorkingCopyDrop.make([patch, photo], repository: repository) == .files([patch, photo]))
        // What is already in the repository is not added to it.
        #expect(WorkingCopyDrop.make([URL(filePath: "/r/app/Sources/a.swift")], repository: repository) == nil)
        #expect(WorkingCopyDrop.make([URL(filePath: "/r/app/a"), photo], repository: repository) == .files([photo]))
        // A sibling folder whose name starts the same is outside.
        #expect(WorkingCopyDrop.make([URL(filePath: "/r/application/a")], repository: repository)
            == .files([URL(filePath: "/r/application/a")]))
        #expect(WorkingCopyDrop.make([URL(string: "https://example.com/a.patch")!], repository: repository) == nil)
        #expect(PatchFileOpening.isPatch(patch))
        #expect(!PatchFileOpening.isPatch(photo))
    }

    private var snapshot: RepositorySnapshot {
        let remote = Branch(id: "refs/remotes/origin/topic", name: "origin/topic", target: oidB, isRemote: true)
        return RepositorySnapshot(
            head: .branch(name: "refs/heads/main", target: oidA),
            branches: [Branch(id: "refs/heads/main", name: "main", target: oidA, isHead: true)],
            remotes: [Remote(name: "origin", url: nil, branches: [remote])]
        )
    }

    @Test func aCommitDroppedOnAHeadingIsNamed() {
        let onBranches = SidebarDropProposal.make(.commits([oidB]), onto: .branches, in: snapshot)
        #expect(onBranches?.choices.map(\.action) == [.newBranch(at: oidB)])
        let onTags = SidebarDropProposal.make(.commits([oidB]), onto: .tags, in: snapshot)
        #expect(onTags?.choices.map(\.action) == [.newTag(at: oidB)])
        // Several commits have no one name to take.
        #expect(SidebarDropProposal.make(.commits([oidA, oidB]), onto: .tags, in: snapshot) == nil)
        #expect(SidebarDropProposal.make(.commits([oidA, oidB]), onto: .branches, in: snapshot) == nil)
    }

    @Test func aReferenceDroppedOnAHeading() {
        let tracked = SidebarDropProposal.make(.reference("refs/remotes/origin/topic"), onto: .branches, in: snapshot)
        #expect(tracked?.choices.map(\.action) == [.trackRemoteBranch("refs/remotes/origin/topic")])
        #expect(SidebarDropProposal.make(.reference("refs/heads/main"), onto: .branches, in: snapshot) == nil)
        let tagged = SidebarDropProposal.make(.reference("refs/remotes/origin/topic"), onto: .tags, in: snapshot)
        #expect(tagged?.choices.map(\.action) == [.newTag(at: oidB)])
        #expect(SidebarDropProposal.make(.reference("refs/tags/v1"), onto: .tags, in: snapshot) == nil)
    }
}

@Suite struct ContinuedProgressTests {
    @Test func aCloneOnlyMovesForward() {
        let steps: [TransferProgress] = [
            TransferProgress(phase: .connecting),
            TransferProgress(phase: .receivingObjects, completed: 0, total: 100),
            TransferProgress(phase: .receivingObjects, completed: 100, total: 100),
            TransferProgress(phase: .resolvingDeltas, completed: 0, total: 50),
            TransferProgress(phase: .resolvingDeltas, completed: 50, total: 50),
            TransferProgress(phase: .checkingOut, completed: 1, total: 10),
            TransferProgress(phase: .checkingOut, completed: 10, total: 10)
        ]
        let units = steps.map(ContinuedProgress.units(for:))
        #expect(units == units.sorted())
        #expect(units.first == 0)
        #expect(units.last == ContinuedProgress.total)
    }

    @Test func aPushFillsTheBar() {
        #expect(ContinuedProgress.units(for: TransferProgress(phase: .sendingObjects, completed: 5, total: 5))
            == ContinuedProgress.total)
        #expect(ContinuedProgress.units(for: TransferProgress(phase: .countingObjects))
            < ContinuedProgress.units(for: TransferProgress(phase: .sendingObjects, completed: 1, total: 5)))
    }
}

@Suite struct CommitMessageDraftTests {
    @Test func readsSubjectAndBody() {
        let message = CommitMessageDraft.parse("Fix crash when the list is empty\n\nThe index was read before the check.\n")
        #expect(message.subject == "Fix crash when the list is empty")
        #expect(message.body == "The index was read before the check.")
        #expect(CommitMessageDraft.parse("Add tests").body.isEmpty)
        #expect(CommitMessageDraft.parse("").subject.isEmpty)
    }

    @Test func forgivesFencesQuotesAndLabels() {
        #expect(CommitMessageDraft.parse("```\nSubject: \"Add a widget.\"\n```").subject == "Add a widget")
        #expect(CommitMessageDraft.parse("\n\n**Rename the app**\n\nBody").subject == "Rename the app")
        // An ellipsis is not a full stop to drop.
        #expect(CommitMessageDraft.parse("Wait for more...").subject == "Wait for more...")
    }

    @Test func keepsAShortPatchWhole() {
        let patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new"
        #expect(CommitMessageDraft.condensed(patch, budget: 10_000) == patch)
    }

    @Test func givesEveryFileAShareOfALongPatch() {
        let body = (0..<400).map { "+line \($0)" }.joined(separator: "\n")
        let patch = ["one", "two", "three"].map { "diff --git a/\($0) b/\($0)\n@@ -0,0 +1,400 @@\n\(body)" }
            .joined(separator: "\n")
        let short = CommitMessageDraft.condensed(patch, budget: 1500)
        #expect(short.count < 2000)
        for name in ["one", "two", "three"] {
            #expect(short.contains("diff --git a/\(name) b/\(name)"))
        }
        #expect(short.contains("left out"))
    }

    @Test func leavesBinaryContentsOut() {
        let patch = "diff --git a/i.png b/i.png\nindex 1..2\nGIT binary patch\nliteral 9999\nzcmV?d00001\n"
        let short = CommitMessageDraft.condensed(patch, budget: 10_000)
        #expect(short.contains("[binary file changed]"))
        #expect(!short.contains("zcmV"))
    }

    @Test func leavesRoomForTheAnswer() {
        #expect(CommitMessageDraft.budget(forContextSize: 4096) < Int(4096 * CommitMessageDraft.charactersPerToken))
        #expect(CommitMessageDraft.budget(forContextSize: 100) > 0)
    }
}

@MainActor
@Suite struct SettingsSyncTests {
    @Test func sendsOnlyWhatChanged() {
        let known: [String: NSObject] = ["pullMode": "merge" as NSString, "fetch.prune": true as NSNumber]
        let local: [String: NSObject] = ["pullMode": "rebase" as NSString, "diff.tabWidth": 8 as NSNumber]
        let changes = SettingsSyncPlan.changed(local: local, known: known)
        #expect(Set(changes.keys) == ["pullMode", "fetch.prune", "diff.tabWidth"])
        #expect(changes["pullMode"] == .some("rebase" as NSString))
        // A setting put back to its default is taken away, not left behind.
        #expect(changes["fetch.prune"] == .some(nil))
        #expect(SettingsSyncPlan.changed(local: known, known: known).isEmpty)
    }

    @Test func neverSyncsWhatBelongsToOneDevice() {
        let keys = Set(SettingsSyncPlan.keys)
        #expect(keys.count == SettingsSyncPlan.keys.count)
        for local in ["menuBar.isShown", "appearance.codeFontSize", "ssh.syncKeys", "sync.settings", "hosting.accountByRepository"] {
            #expect(!keys.contains(local))
        }
    }

    private func library() -> RepositoryLibrary {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WyeUITests-\(UUID().uuidString)")
        return RepositoryLibrary(
            storage: folder.appending(path: "Repositories.json"), documents: folder.appending(path: "Documents"),
            filesStorage: nil
        )
    }

    @Test func groupsTravelByName() {
        let library = library()
        let work = library.createGroup(named: "Work")
        library.bookmarks = [
            RepositoryBookmark(name: "app", location: .documents("app"), groupID: work.id),
            RepositoryBookmark(name: "notes", location: .documents("notes"))
        ]
        let synced = SettingsSyncPlan.groups(of: library.bookmarks, in: library.groups)
        #expect(synced == SettingsSyncPlan.Groups(names: ["Work"], membership: ["app": "Work"]))
    }

    @Test func appliesAnotherDevicesGroups() {
        let library = library()
        let play = library.createGroup(named: "Play")
        library.bookmarks = [
            RepositoryBookmark(name: "app", location: .documents("app")),
            RepositoryBookmark(name: "game", location: .documents("game"), groupID: play.id),
            RepositoryBookmark(name: "notes", location: .documents("notes"))
        ]
        library.apply(SettingsSyncPlan.Groups(names: ["Work"], membership: ["app": "Work", "elsewhere": "Work"]))
        let work = library.groups.first { $0.name == "Work" }
        #expect(work != nil)
        #expect(library.bookmarks.first { $0.name == "app" }?.groupID == work?.id)
        // What the other device does not mention stays as it is here.
        #expect(library.bookmarks.first { $0.name == "game" }?.groupID == play.id)
        #expect(library.bookmarks.first { $0.name == "notes" }?.groupID == nil)
        #expect(library.groups.map(\.name) == ["Play", "Work"])
    }
}

@MainActor
@Suite struct SystemIntegrationTests {
    @Test func finderBadgesFollowTheStatus() {
        #expect(FinderStatusPublisher.badge(for: StatusEntry(path: "a", staged: nil, unstaged: .modified)) == .modified)
        #expect(FinderStatusPublisher.badge(for: StatusEntry(path: "a", staged: .added, unstaged: nil)) == .staged)
        #expect(FinderStatusPublisher.badge(for: StatusEntry(path: "a", staged: .added, unstaged: .modified)) == .modified)
        #expect(FinderStatusPublisher.badge(for: StatusEntry(path: "a", staged: nil, unstaged: .untracked)) == .untracked)
        #expect(FinderStatusPublisher.badge(for: StatusEntry(path: "a", staged: nil, unstaged: .conflicted)) == .conflicted)
        let status = FinderStatusPublisher.status(
            id: UUID(), name: "app", root: URL(filePath: "/r/app/", directoryHint: .isDirectory), branch: "main",
            entries: [StatusEntry(path: "x/y.swift", staged: nil, unstaged: .modified)]
        )
        #expect(status.root == "/r/app")
        #expect(status.badges == ["x/y.swift": .modified])
    }

    @Test func onlyNotableOperationsAreFelt() {
        func entry(_ title: String, transfer: TransferProgress? = nil, background: Bool = false) -> ActivityEntry {
            ActivityEntry(id: UUID(), title: title, repository: "r", started: .now, finished: .now,
                          outcome: .succeeded, transfer: transfer, isBackground: background)
        }
        #expect(ActivityLog.isNotable(entry("Commit")))
        #expect(ActivityLog.isNotable(entry("Push “origin”")))
        #expect(ActivityLog.isNotable(entry("Prune", transfer: TransferProgress(phase: .connecting))))
        #expect(!ActivityLog.isNotable(entry("Stage")))
        #expect(!ActivityLog.isNotable(entry("Fetch", background: true)))
    }

    @Test func countsWhatIsWorthFeeling() {
        let log = ActivityLog()
        log.finish(log.begin("Stage", repository: "r"), error: nil)
        #expect(log.completions == 0)
        log.finish(log.begin("Commit", repository: "r"), error: nil)
        #expect(log.completions == 1)
        log.finish(log.begin("Stage", repository: "r"), error: CocoaError(.fileNoSuchFile))
        #expect(log.failures == 1)
        log.finish(log.begin("Fetch", repository: "r", isBackground: true), error: CocoaError(.fileNoSuchFile))
        #expect(log.failures == 1)
        log.finish(log.begin("Pull", repository: "r"), error: CancellationError())
        #expect(log.failures == 1 && log.completions == 1)
    }

    @Test func saysDiffLinesAsWhatTheyAre() {
        typealias Line = FileDiff.Line
        #expect(DiffAccessibility.label(for: Line(id: 0, kind: .addition, oldNumber: nil, newNumber: 12, text: "  let x = 1"))
            == "Added, line 12: let x = 1")
        #expect(DiffAccessibility.label(for: Line(id: 1, kind: .deletion, oldNumber: 7, newNumber: nil, text: ""))
            == "Removed, line 7: blank")
        #expect(DiffAccessibility.label(for: Line(id: 2, kind: .context, oldNumber: 3, newNumber: 4, text: "}"))
            == "Line 4: }")
        let hunk = FileDiff.Hunk(id: 0, header: "@@ -3,2 +3,3 @@", lines: [
            Line(id: 0, kind: .context, oldNumber: 3, newNumber: 3, text: "a"),
            Line(id: 1, kind: .deletion, oldNumber: 4, newNumber: nil, text: "b"),
            Line(id: 2, kind: .addition, oldNumber: nil, newNumber: 4, text: "c"),
            Line(id: 3, kind: .addition, oldNumber: nil, newNumber: 5, text: "d")
        ])
        #expect(DiffAccessibility.label(forHunk: hunk) == "Changes at line 3: 2 added, 1 removed")
    }

    @Test func aFileGetsToAnotherAppOneWayOnly() {
        // Open where the system has an app for a file, Share where it has none.
        #expect(Platform.canOpenFilesInOtherApps != Platform.sharesFilesToOpenThem)
        #if os(macOS)
        #expect(Platform.canOpenFilesInOtherApps)
        // A repository opens beside another in a tab of the window.
        #expect(Platform.opensRepositoriesBeside && Platform.hasWindowTabs)
        #endif
    }

    #if os(macOS)
    @Test func theMenuBarListsWhatNeedsAttention() {
        func summary(_ name: String, ahead: Int = 0, behind: Int = 0, changes: Bool = false, minutesAgo: Double) -> RepositoryStatusSummary {
            RepositoryStatusSummary(id: UUID(), name: name, branch: "main", ahead: ahead, behind: behind,
                                    hasUncommittedChanges: changes, updated: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
        }
        let clean = summary("clean", minutesAgo: 0), old = summary("old", ahead: 1, minutesAgo: 30)
        let behind = summary("behind", behind: 2, minutesAgo: 5), unlisted = summary("unlisted", ahead: 9, minutesAgo: 1)
        let summaries = Dictionary(uniqueKeysWithValues: [clean, old, behind, unlisted].map { ($0.id, $0) })
        let list = MenuBarStatusList([clean.id, old.id, behind.id], summaries: summaries)
        #expect(list.attention.map(\.name) == ["behind", "old"])
        #expect(MenuBarStatusList.title(for: summary("app", ahead: 2, behind: 1, changes: true, minutesAgo: 0))
            == "app — main ↑2 ↓1 ✎")
        #expect(MenuBarStatusList.title(for: clean) == "clean — main")
    }
    #endif
}

@MainActor
@Suite struct SettingsSyncAvailabilityTests {
    @Test func isOfferedOnlyInABuildSignedForIt() {
        #expect(!SettingsSync.isAvailable(info: nil))
        #expect(!SettingsSync.isAvailable(info: [:]))
        #expect(!SettingsSync.isAvailable(info: [SettingsSync.infoKey: false]))
        #expect(SettingsSync.isAvailable(info: [SettingsSync.infoKey: true]))
    }
}
