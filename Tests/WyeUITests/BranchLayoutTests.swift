import Foundation
import GitKit
import Testing
@testable import WyeUI

/// Pinning, archiving, the merged and stale marks, and where the layout is kept.
@MainActor
@Suite struct BranchLayoutTests {
    private let commit = OID(hex: "0123456789abcdef0123456789abcdef01234567")!
    private let now = ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z")!

    private func branch(_ name: String, head: Bool = false) -> Branch {
        Branch(id: "refs/heads/" + name, name: name, target: commit, isHead: head)
    }

    private func monthsAgo(_ months: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: -months, to: now)!
    }

    private var branches: [Branch] {
        [branch("alpha"), branch("main", head: true), branch("old"), branch("pinned"), branch("shelved")]
    }

    private var review: BranchReview {
        BranchReview(
            base: "refs/heads/main",
            merged: ["refs/heads/alpha", "refs/heads/old"],
            tipDates: [
                "refs/heads/alpha": monthsAgo(1), "refs/heads/main": monthsAgo(9), "refs/heads/old": monthsAgo(8),
                "refs/heads/pinned": monthsAgo(12), "refs/heads/shelved": monthsAgo(0)
            ]
        )
    }

    private func names(_ branches: [Branch]) -> [String] { branches.map(\.name) }

    @Test func pinnedComeFirstAndArchivedLeaveTheList() {
        let state = RepositoryInterfaceState.Stored(pinned: ["refs/heads/pinned"], archived: ["refs/heads/shelved"])
        let listing = BranchListing(branches: branches, state: state, review: review, now: now,
                                    staleMonths: 3, autoArchiveMonths: 0)
        #expect(names(listing.pinned) == ["pinned"])
        #expect(names(listing.listed) == ["alpha", "main", "old"])
        #expect(names(listing.archived) == ["shelved"])
        #expect(listing.marks["refs/heads/pinned"]?.isPinned == true)
        #expect(listing.marks["refs/heads/shelved"]?.isAutoArchived == false)
    }

    @Test func mergedAndStaleMarks() {
        let state = RepositoryInterfaceState.Stored(hidesMergedMark: ["refs/heads/old"])
        let listing = BranchListing(branches: branches, state: state, review: review, now: now,
                                    staleMonths: 3, autoArchiveMonths: 0)
        #expect(listing.marks["refs/heads/alpha"] == .init(isMerged: true))
        // Its merged mark hidden, its age still shows.
        #expect(listing.marks["refs/heads/old"] == .init(isStale: true))
        #expect(listing.marks["refs/heads/pinned"]?.isStale == true)
        // The checked-out branch is neither merged nor stale.
        #expect(listing.marks["refs/heads/main"] == .init())
        let never = BranchListing(branches: branches, state: state, review: review, now: now,
                                  staleMonths: 0, autoArchiveMonths: 0)
        #expect(never.marks.values.allSatisfy { !$0.isStale })
    }

    @Test func oldBranchesArchiveThemselvesUnlessExemptPinnedOrCheckedOut() {
        let state = RepositoryInterfaceState.Stored(pinned: ["refs/heads/pinned"], skipsAutoArchiving: ["refs/heads/alpha"])
        var dated = review
        dated.tipDates["refs/heads/alpha"] = monthsAgo(30)
        let listing = BranchListing(branches: branches, state: state, review: dated, now: now,
                                    staleMonths: 3, autoArchiveMonths: 6)
        #expect(names(listing.archived) == ["old"])
        #expect(listing.marks["refs/heads/old"]?.isAutoArchived == true)
        #expect(names(listing.pinned) == ["pinned"])
        #expect(names(listing.listed) == ["alpha", "main", "shelved"])
        // Without a review there are no dates, so nothing is archived for its age.
        let unknown = BranchListing(branches: branches, state: state, review: nil, now: now,
                                    staleMonths: 3, autoArchiveMonths: 6)
        #expect(unknown.archived.isEmpty)
    }

    @Test func theCheckedOutBranchStaysInViewEvenWhenArchived() {
        let state = RepositoryInterfaceState.Stored(archived: ["refs/heads/main"])
        let listing = BranchListing(branches: branches, state: state, review: review, now: now,
                                    staleMonths: 3, autoArchiveMonths: 0)
        #expect(listing.archived.isEmpty)
        #expect(names(listing.listed).contains("main"))
    }

    @Test func pinningAndArchivingExcludeEachOther() {
        let state = RepositoryInterfaceState(storage: nil)
        state.setPinned("refs/heads/a", true)
        state.setArchived("refs/heads/a", true)
        #expect(!state.isPinned("refs/heads/a"))
        #expect(state.isArchivedByHand("refs/heads/a"))
        state.setPinned("refs/heads/a", true)
        #expect(!state.isArchivedByHand("refs/heads/a"))
        // Unarchiving one archived for its age exempts it, or it would go straight back.
        state.unarchive("refs/heads/b", wasAutomatic: true)
        #expect(state.skipsAutoArchiving("refs/heads/b"))
    }

    @Test func renamesKeepAndDeletesForgetTheLayout() {
        let state = RepositoryInterfaceState(storage: nil)
        state.setPinned("refs/heads/a", true)
        state.setHidesMergedMark("refs/heads/a", true)
        state.renamed("refs/heads/a", to: "refs/heads/b")
        #expect(state.isPinned("refs/heads/b") && state.hidesMergedMark("refs/heads/b"))
        #expect(!state.isPinned("refs/heads/a"))
        state.forget("refs/heads/b")
        #expect(state.stored == .init())
    }

    @Test func theLayoutIsKeptOnDisk() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "WyeUITests-\(UUID().uuidString)/Interface/layout.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let state = RepositoryInterfaceState(storage: file)
        state.setPinned("refs/heads/a", true)
        state.setArchived("refs/heads/b", true)
        state.setSkipsAutoArchiving("refs/heads/c", true)
        let reopened = RepositoryInterfaceState(storage: file)
        #expect(reopened.stored == state.stored)
        #expect(reopened.isPinned("refs/heads/a"))
    }

    @Test func theReviewIsWorkedOutOncePerSetOfBranches() {
        let state = RepositoryInterfaceState(storage: nil)
        let snapshot = RepositorySnapshot(head: .branch(name: "refs/heads/main", target: commit), branches: branches)
        #expect(state.needsReview(of: snapshot))
        state.take(review, for: snapshot)
        #expect(!state.needsReview(of: snapshot))
        // A new stash is no reason to look at the branches again.
        var stashed = snapshot
        stashed.stashes = [Stash(id: commit, index: 0, message: "On main: x", date: now)]
        #expect(!state.needsReview(of: stashed))
        var moved = snapshot
        moved.branches.append(branch("new"))
        #expect(state.needsReview(of: moved))
    }
}
