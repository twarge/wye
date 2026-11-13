import Foundation
import GitKit
import Testing
@testable import WyeUI

/// Sorting, shortening and filtering the sidebar's lists, and what drops
/// onto it offer.
@MainActor
@Suite struct SidebarListTests {
    private let one = OID(hex: "1111111111111111111111111111111111111111")!
    private let two = OID(hex: "2222222222222222222222222222222222222222")!

    // MARK: Sorting

    @Test func versionsSortByValue() {
        let names = ["v1.9", "v1.10", "v1.2.0", "v1.2.0-rc1", "v1.2.0-rc2", "v2", "v1.2.0.1", "beta", "v1.10.0-beta"]
        let sorted = SidebarSort.version.sorted(names, name: { $0 }, date: { _ in nil })
        #expect(sorted == ["v2", "v1.10", "v1.10.0-beta", "v1.9", "v1.2.0.1", "v1.2.0", "v1.2.0-rc2", "v1.2.0-rc1", "beta"])
        #expect(VersionOrder.precedes("1.0.0-alpha", "1.0.0-beta"))
        #expect(!VersionOrder.precedes("1.0.0", "1.0.0"))
    }

    @Test func namesSortAsText() {
        let sorted = SidebarSort.name.sorted(["v1.9", "v1.10", "Alpha", "beta"], name: { $0 }, date: { _ in nil })
        #expect(sorted == ["Alpha", "beta", "v1.10", "v1.9"])
    }

    @Test func recentFirstThenByName() {
        let dates = ["a": Date(timeIntervalSince1970: 10), "b": Date(timeIntervalSince1970: 30), "c": Date(timeIntervalSince1970: 30)]
        let sorted = SidebarSort.recent.sorted(["a", "c", "b", "undated"], name: { $0 }, date: { dates[$0] })
        #expect(sorted == ["b", "c", "a", "undated"])
    }

    @Test func longListsAreShortened() {
        let items = Array(0..<100)
        let short = Shortened(items, showsAll: false)
        #expect(short.shown == Array(0..<30))
        #expect(short.hiddenCount == 70)
        #expect(Shortened(items, showsAll: true).shown.count == 100)
        // A few over the limit are not worth hiding.
        #expect(Shortened(Array(0..<33), showsAll: false).hiddenCount == 0)
    }

    @Test func onlyTheMostRecentTagsAreListed() {
        // Named so that neither name nor version order is date order.
        let dates = Dictionary(uniqueKeysWithValues: ["v3", "v1", "v7", "v5", "v2", "v6", "v4"].enumerated().map {
            ($1, Date(timeIntervalSince1970: TimeInterval(100 - $0)))
        })
        let names = dates.keys.sorted()
        func listed(_ limit: Int, showsAll: Bool = false, sort: SidebarSort = .recent, selected: String? = nil) -> Shortened<String> {
            Shortened(
                mostRecent: limit, of: names, showsAll: showsAll, sort: sort,
                name: { $0 }, date: { dates[$0] }, keeps: { $0 == selected }
            )
        }
        let short = listed(5)
        #expect(short.shown == ["v3", "v1", "v7", "v5", "v2"])
        #expect(short.hiddenCount == 2)
        // The same five whatever the order they are listed in.
        #expect(listed(5, sort: .name).shown == ["v1", "v2", "v3", "v5", "v7"])
        #expect(listed(5, sort: .version).shown == ["v7", "v5", "v3", "v2", "v1"])
        // One more than the limit is already too many; the limit itself is not.
        #expect(listed(6).hiddenCount == 1)
        #expect(listed(7).hiddenCount == 0)
        #expect(listed(7, sort: .name).shown == names)
        #expect(listed(5, showsAll: true, sort: .version).shown == ["v7", "v6", "v5", "v4", "v3", "v2", "v1"])
        // The selected tag stays listed, in its place.
        #expect(listed(5, selected: "v4").shown == ["v3", "v1", "v7", "v5", "v2", "v4"])
        #expect(listed(5, sort: .name, selected: "v4").shown == ["v1", "v2", "v3", "v4", "v5", "v7"])
        #expect(listed(5, selected: "v4").hiddenCount == 1)
        #expect(listed(5, selected: "v3").shown.count == 5)
    }

    @Test func tagLimitDefaultsToFive() {
        #expect(SidebarPreferences.defaultTagLimit == 5)
        #expect(SidebarPreferences.tagLimit(12) == 12)
        // Whatever ended up in the defaults, some tags are listed.
        #expect(SidebarPreferences.tagLimit(0) == 1)
        #expect(SidebarPreferences.tagLimit(-3) == 1)
        #expect(SidebarPreferences.tagLimit(5000) == 100)
        #expect(SettingsSyncPlan.keys.contains(SidebarPreferences.tagLimitKey))
    }

    @Test func optionsReadWhatTheyCan() throws {
        let decoded = try JSONDecoder().decode(SidebarListOptions.self, from: Data(#"{"tagSort":"version"}"#.utf8))
        #expect(decoded.tagSort == .version)
        // What was not saved takes the default: most recent first.
        #expect(decoded.remoteBranchSort == .recent)
        #expect(SidebarListOptions().tagSort == .recent)
        var options = SidebarListOptions()
        options.remotesShowingAll = ["origin"]
        let roundTrip = try JSONDecoder().decode(SidebarListOptions.self, from: JSONEncoder().encode(options))
        #expect(roundTrip == options)
    }

    @Test func optionsPersistPerRepository() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SidebarListTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = SidebarListOptions()
        options.tagSort = .version
        RepositoryInterfaceState(storage: url).setSidebarLists(options)
        let tracker = IssueTracker(urlTemplate: "https://example.atlassian.net/browse/$0")
        RepositoryInterfaceState(storage: url).setIssueTrackers([tracker])
        let reread = RepositoryInterfaceState(storage: url)
        #expect(reread.sidebarLists.tagSort == .version)
        #expect(reread.issueTrackers == [tracker])
    }

    @Test func stateFromBeforeTheseOptionsStillReads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SidebarListTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version":1,"pinned":["refs/heads/a"],"archived":[],"skipsAutoArchiving":[],"hidesMergedMark":[]}"#.utf8)
            .write(to: url)
        let state = RepositoryInterfaceState(storage: url)
        #expect(state.isPinned("refs/heads/a"))
        #expect(state.issueTrackers.isEmpty)
        #expect(state.sidebarLists == SidebarListOptions())
    }

    // MARK: Filtering

    @Test func filterMatchesEveryWord() {
        #expect(SidebarFilter.matches("feature/login-page", "login"))
        #expect(SidebarFilter.matches("feature/login-page", "FEAT page"))
        #expect(!SidebarFilter.matches("feature/login-page", "logout"))
        #expect(SidebarFilter.matches("anything", "  "))
    }

    @Test func filteringOpensFoldersClosedByDefault() {
        let branches = ["feature/a/one", "feature/b", "fix/c", "main"].map {
            Branch(id: "refs/heads/" + $0, name: $0, target: one)
        }
        let nodes = BranchFolderNode.tree(of: branches, path: \.name, idPrefix: "local:")
        #expect(SidebarFilter.closedFolders(in: nodes, headBranch: nil) == ["local:feature/", "local:feature/a/", "local:fix/"])
        // The checked-out branch's folders open by default already.
        #expect(SidebarFilter.closedFolders(in: nodes, headBranch: "refs/heads/feature/b") == ["local:feature/a/", "local:fix/"])
    }

    // MARK: Drops

    private var snapshot: RepositorySnapshot {
        RepositorySnapshot(
            head: .branch(name: "refs/heads/main", target: one),
            branches: [
                Branch(id: "refs/heads/main", name: "main", target: one, isHead: true),
                Branch(id: "refs/heads/topic", name: "topic", target: two),
                Branch(id: "refs/heads/elsewhere", name: "elsewhere", target: two, worktreePath: "/tmp/w")
            ],
            remotes: [Remote(name: "origin", url: nil, branches: [
                Branch(id: "refs/remotes/origin/main", name: "origin/main", target: one, isRemote: true)
            ])],
            tags: [GitKit.Tag(id: "refs/tags/v1", name: "v1", target: two)]
        )
    }

    private func actions(_ strings: [String], _ target: SidebarDropTarget) -> [SidebarDropProposal.Action]? {
        SidebarDragPayload(strings).flatMap { SidebarDropProposal.make($0, onto: target, in: snapshot) }?.choices.map(\.action)
    }

    @Test func payloadsReadBack() {
        #expect(SidebarDragPayload([SidebarDragPayload.text(for: [one, two])]) == .commits([one, two]))
        #expect(SidebarDragPayload(["refs/heads/topic"]) == .reference("refs/heads/topic"))
        #expect(SidebarDragPayload(["some text"]) == nil)
        #expect(SidebarDragPayload(["refs/heads/a\nrefs/heads/b"]) == nil)
    }

    @Test func commitsOntoBranches() {
        #expect(actions([one.hex, two.hex], .branch("refs/heads/main")) == [.cherryPick([one, two])])
        #expect(actions([two.hex], .branch("refs/heads/topic")) == [.checkOutAndCherryPick(branch: "refs/heads/topic", [two])])
        // Checked out in another worktree: nothing to offer here.
        #expect(actions([two.hex], .branch("refs/heads/elsewhere")) == nil)
        #expect(actions([two.hex], .workingCopy) == [.checkOutCommit(two)])
        #expect(actions([one.hex], .workingCopy) == nil)
    }

    @Test func branchesOntoBranches() {
        #expect(actions(["refs/heads/topic"], .branch("refs/heads/main")) == [.merge("refs/heads/topic"), .rebase(onto: "refs/heads/topic")])
        #expect(actions(["refs/heads/main"], .branch("refs/heads/topic")) == [
            .rebase(onto: "refs/heads/topic"), .checkOutAndMerge(branch: "refs/heads/topic", merging: "refs/heads/main")
        ])
        #expect(actions(["refs/tags/v1"], .branch("refs/heads/topic")) == [
            .checkOutAndMerge(branch: "refs/heads/topic", merging: "refs/tags/v1")
        ])
        #expect(actions(["refs/heads/main"], .branch("refs/heads/main")) == nil)
    }

    @Test func referencesOntoTheWorkingCopy() {
        #expect(actions(["refs/heads/topic"], .workingCopy) == [.checkOutBranch("refs/heads/topic")])
        #expect(actions(["refs/heads/main"], .workingCopy) == nil)
        #expect(actions(["refs/tags/v1"], .workingCopy) == [.checkOutTag("refs/tags/v1")])
        #expect(actions(["refs/remotes/origin/main"], .workingCopy) == [.trackRemoteBranch("refs/remotes/origin/main")])
    }
}
