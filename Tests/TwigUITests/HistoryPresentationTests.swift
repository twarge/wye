import Foundation
import GitKit
import Testing
@testable import TwigUI

/// Which badges a commit shows, the history's filter tokens, and the links
/// found in commit messages.
@MainActor
@Suite struct HistoryPresentationTests {
    private let one = OID(hex: "1111111111111111111111111111111111111111")!
    private let two = OID(hex: "2222222222222222222222222222222222222222")!

    private func local(_ name: String, at target: OID, upstream: String? = nil, head: Bool = false) -> Branch {
        Branch(id: "refs/heads/" + name, name: name, target: target, isHead: head,
               upstream: upstream.map { Branch.Upstream(name: $0, ahead: 0, behind: 0) })
    }

    private func remote(_ name: String, at target: OID) -> Branch {
        Branch(id: "refs/remotes/" + name, name: name, target: target, isRemote: true)
    }

    private func snapshot(head: Head, branches: [Branch], remotes: [String: [Branch]], tags: [GitKit.Tag] = []) -> RepositorySnapshot {
        RepositorySnapshot(
            head: head, branches: branches,
            remotes: remotes.keys.sorted().map { Remote(name: $0, url: nil, branches: remotes[$0]!) }, tags: tags
        )
    }

    // MARK: Badges

    @Test func headHasNoBadgeOnABranch() {
        let labels = RefLabel.labels(in: snapshot(
            head: .branch(name: "refs/heads/main", target: one),
            branches: [local("main", at: one, head: true)], remotes: [:]
        ))
        #expect(labels[one] == [RefLabel(name: "main", kind: .branch)])
    }

    @Test func detachedHeadKeepsAMarker() {
        let labels = RefLabel.labels(in: snapshot(head: .detached(two), branches: [local("main", at: one)], remotes: [:]))
        #expect(labels[two] == [RefLabel(name: "HEAD", kind: .head)])
    }

    @Test func remoteHeadIsHidden() {
        let labels = RefLabel.labels(in: snapshot(
            head: .branch(name: "refs/heads/main", target: one), branches: [],
            remotes: ["origin": [remote("origin/HEAD", at: one), remote("origin/dev", at: one)]]
        ))
        #expect(labels[one] == [RefLabel(name: "origin/dev", kind: .remote)])
    }

    @Test func upstreamAtTheSameCommitJoinsTheBadge() {
        let labels = RefLabel.labels(in: snapshot(
            head: .branch(name: "refs/heads/main", target: one),
            branches: [local("main", at: one, upstream: "origin/main", head: true), local("topic", at: two, upstream: "origin/topic")],
            remotes: ["origin": [remote("origin/main", at: one), remote("origin/topic", at: one)]],
            tags: [GitKit.Tag(id: "refs/tags/v1", name: "v1", target: one)]
        ))
        // On different commits, `topic` and `origin/topic` stay apart.
        #expect(labels[one] == [
            RefLabel(name: "main", kind: .branch, remotes: ["origin/main"]),
            RefLabel(name: "v1", kind: .tag),
            RefLabel(name: "origin/topic", kind: .remote)
        ])
        #expect(labels[two] == [RefLabel(name: "topic", kind: .branch)])
    }

    @Test func sameNamesJoinWithoutAnUpstream() {
        let labels = RefLabel.labels(in: snapshot(
            head: .branch(name: "refs/heads/main", target: one),
            branches: [local("main", at: one)],
            remotes: [
                "origin": [remote("origin/main", at: one)],
                "upstream": [remote("upstream/main", at: one), remote("upstream/other", at: one)]
            ]
        ))
        #expect(labels[one] == [
            RefLabel(name: "main", kind: .branch, remotes: ["origin/main", "upstream/main"]),
            RefLabel(name: "upstream/other", kind: .remote)
        ])
    }

    @Test func anUpstreamGoesToTheBranchThatTracksIt() {
        // `main` shares a name with `origin/main`, but `release` tracks it.
        let labels = RefLabel.labels(in: snapshot(
            head: .branch(name: "refs/heads/main", target: one),
            branches: [local("main", at: one), local("release", at: one, upstream: "origin/main")],
            remotes: ["origin": [remote("origin/main", at: one)]]
        ))
        #expect(labels[one] == [
            RefLabel(name: "main", kind: .branch),
            RefLabel(name: "release", kind: .branch, remotes: ["origin/main"])
        ])
    }

    // MARK: Filters

    @Test func tokensRemoveTheirFilters() {
        let ada = HistoryFilter.Author(name: "Ada", email: "ada@example.com")
        let since = Date(timeIntervalSince1970: 1_000)
        var filters = HistoryFilters(since: since, authors: [ada], shownBranches: ["refs/heads/main"])
        filters.toggleHidden("refs/heads/topic")
        #expect(filters.tokens == [.since(since), .author(ada), .shownBranch("refs/heads/main"), .hiddenBranch("refs/heads/topic")])
        #expect(!filters.commitFilter.isEmpty)

        let kept = filters.keeping(filters.tokens.filter { $0 != .author(ada) && $0 != .since(since) })
        #expect(kept.authors.isEmpty && kept.since == nil)
        #expect(kept.commitFilter.isEmpty)
        #expect(kept.shownBranches == ["refs/heads/main"])
        let options = kept.applied(to: HistoryOptions(order: .topological))
        #expect(options == HistoryOptions(order: .topological, includedReferences: ["refs/heads/main"],
                                          hiddenReferences: ["refs/heads/topic"]))
        #expect(kept.keeping([]).isEmpty)
    }

    @Test func showingABranchStopsHidingIt() {
        var filters = HistoryFilters()
        filters.toggleHidden("refs/heads/a")
        filters.toggleShown("refs/heads/a")
        #expect(filters.hiddenBranches.isEmpty && filters.shownBranches == ["refs/heads/a"])
        filters.toggleShown("refs/heads/a")
        #expect(filters.isEmpty)
    }

    // MARK: Links

    private func linked(_ text: String, _ linker: MessageLinker) -> [String: String] {
        Dictionary(uniqueKeysWithValues: linker.links(in: text).map { (String(text[$0.range]), $0.url.absoluteString) })
    }

    @Test func githubReferences() throws {
        let linker = MessageLinker(hosted: HostedRepository(remoteURL: "git@github.com:owner/project.git"))
        let text = "Fix #12 and GH-34, see other/repo#5 and https://example.com/a#7. Not a#1, &#38; or issue#9."
        #expect(linked(text, linker) == [
            "#12": "https://github.com/owner/project/issues/12",
            "GH-34": "https://github.com/owner/project/issues/34",
            "other/repo#5": "https://github.com/other/repo/issues/5",
            "https://example.com/a#7": "https://example.com/a#7"
        ])
    }

    @Test func gitlabMergeRequests() {
        let linker = MessageLinker(hosted: HostedRepository(remoteURL: "https://gitlab.com/group/project.git"))
        #expect(linked("Closes #3, follows !45", linker) == [
            "#3": "https://gitlab.com/group/project/-/issues/3",
            "!45": "https://gitlab.com/group/project/-/merge_requests/45"
        ])
        // `!` and `GH-` mean nothing on GitHub and GitLab respectively.
        let github = MessageLinker(hosted: HostedRepository(remoteURL: "https://github.com/o/p"))
        #expect(linked("Wow!45", github).isEmpty)
        #expect(linked("GH-1", linker).isEmpty)
    }

    @Test func trackersOnlyWhenConfigured() throws {
        let text = "ABC-123: tidy up (#4)"
        #expect(linked(text, MessageLinker()).isEmpty)
        let tracker = IssueTracker(urlTemplate: "https://example.atlassian.net/browse/$0")
        #expect(tracker.isValid)
        let linker = MessageLinker(hosted: HostedRepository(remoteURL: "https://github.com/o/p"), trackers: [tracker])
        #expect(linked(text, linker) == [
            "ABC-123": "https://example.atlassian.net/browse/ABC-123",
            "#4": "https://github.com/o/p/issues/4"
        ])
        // Groups fill in their own places.
        let grouped = IssueTracker(pattern: "\\bT([0-9]+)\\b", urlTemplate: "https://tracker.example/task/$1")
        #expect(linked("See T42", MessageLinker(trackers: [grouped])) == ["T42": "https://tracker.example/task/42"])
        #expect(!IssueTracker(pattern: "(", urlTemplate: "https://x/$0").isValid)
    }

    @Test func linksBecomeAttributes() {
        let linker = MessageLinker(hosted: HostedRepository(remoteURL: "https://github.com/o/p"))
        let attributed = linker.attributed("Fix #1 now")
        let links = attributed.runs.compactMap { run in run.link.map { (String(attributed[run.range].characters), $0) } }
        #expect(links.count == 1)
        #expect(links.first?.0 == "#1")
        #expect(links.first?.1.absoluteString == "https://github.com/o/p/issues/1")
    }
}
