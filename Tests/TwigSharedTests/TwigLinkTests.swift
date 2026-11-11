import Foundation
import Testing
@testable import TwigShared

@Suite struct TwigLinkTests {
    let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    @Test func readsAnOpenLink() {
        let url = URL(string: "twig://open?repository=6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        #expect(TwigLink(url) == .openRepository(id))
    }

    @Test func readsTheSchemeAndActionInAnyCase() {
        let url = URL(string: "TWIG://Open?repository=6f9619ff-8b86-d011-b42d-00c04fc964ff")!
        #expect(TwigLink(url) == .openRepository(id))
    }

    @Test func readsACloneLink() {
        let url = URL(string: "twig://clone?url=https%3A%2F%2Fexample.com%2Fowner%2Fproject.git")!
        #expect(TwigLink(url) == .clone("https://example.com/owner/project.git"))
    }

    @Test func readsALinkWithoutSlashes() {
        #expect(TwigLink(URL(string: "twig:clone?url=git@example.com:owner/project.git")!)
            == .clone("git@example.com:owner/project.git"))
    }

    @Test(arguments: [
        "https://example.com/open?repository=6F9619FF-8B86-D011-B42D-00C04FC964FF",
        "twig://open",
        "twig://open?repository=not-an-id",
        "twig://clone",
        "twig://clone?url=%20",
        "twig://delete?repository=6F9619FF-8B86-D011-B42D-00C04FC964FF",
        "file:///Users/me/project"
    ])
    func refusesOtherURLs(_ text: String) {
        #expect(TwigLink(URL(string: text)!) == nil)
    }

    @Test(arguments: [
        "https://example.com/owner/project.git",
        "git@example.com:owner/project.git",
        "ssh://git@example.com:2222/owner/project",
        "https://user@example.com/a&b=c+d/project?x#y"
    ])
    func makesLinksThatReadBack(_ address: String) {
        let link = TwigLink.clone(address)
        #expect(link.url.scheme == "twig")
        #expect(TwigLink(link.url) == link)
    }

    @Test func makesOpenLinksThatReadBack() {
        let link = TwigLink.openRepository(id)
        #expect(link.url.absoluteString == "twig://open?repository=6F9619FF-8B86-D011-B42D-00C04FC964FF")
        #expect(TwigLink(link.url) == link)
    }
}

@Suite struct RemoteAddressFinderTests {
    @Test(arguments: [
        ("https://example.com/owner/project.git", "https://example.com/owner/project.git"),
        ("https://example.com/owner/project", "https://example.com/owner/project"),
        ("git@example.com:owner/project.git", "git@example.com:owner/project.git"),
        ("ssh://git@example.com:2222/owner/project.git", "ssh://git@example.com:2222/owner/project.git"),
        // A page inside the repository's site goes back to the repository.
        ("https://example.com/owner/project/tree/main/Sources", "https://example.com/owner/project"),
        ("https://example.com/group/sub/project/-/blob/main/README.md", "https://example.com/group/sub/project"),
        ("https://example.com/owner/project?tab=readme#top", "https://example.com/owner/project"),
        // In a sentence, with punctuation around it.
        ("Clone (https://example.com/owner/project.git), then build.", "https://example.com/owner/project.git"),
        ("Try git@example.com:owner/project.git.", "git@example.com:owner/project.git"),
        ("first https://example.com/a/b and https://example.com/c/d", "https://example.com/a/b")
    ])
    func findsAnAddress(_ text: String, _ expected: String) {
        #expect(RemoteAddressFinder.firstAddress(in: text) == expected)
    }

    @Test(arguments: [
        "",
        "no address here",
        "https://example.com",
        "https://example.com/about",
        "mail me@example.com about it",
        "ftp://example.com/owner/project.git",
        "/Users/me/project"
    ])
    func findsNoAddress(_ text: String) {
        #expect(RemoteAddressFinder.firstAddress(in: text) == nil)
    }
}

@Suite struct UnpushedChangesTests {
    func summary(
        _ name: String, ahead: Int = 0, behind: Int = 0, changes: Bool = false, minutesAgo: Double
    ) -> RepositoryStatusSummary {
        RepositoryStatusSummary(
            id: UUID(), name: name, branch: "main", ahead: ahead, behind: behind,
            hasUncommittedChanges: changes, updated: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60)
        )
    }

    @Test func listsOnlyRepositoriesWithUnpushedWork() {
        let changes = UnpushedChanges([
            summary("Clean", minutesAgo: 1),
            summary("Behind only", behind: 3, minutesAgo: 2),
            summary("Ahead", ahead: 2, minutesAgo: 3),
            summary("Edited", changes: true, minutesAgo: 4)
        ])
        #expect(changes.repositories.map(\.name) == ["Ahead", "Edited"])
        #expect(changes.total == 2)
        #expect(!changes.isEmpty)
    }

    @Test func putsTheMostRecentlyUpdatedFirstAndTiesByName() {
        let changes = UnpushedChanges([
            summary("Old", ahead: 1, minutesAgo: 60),
            summary("beta", ahead: 1, minutesAgo: 5),
            summary("Alpha", changes: true, minutesAgo: 5),
            summary("New", ahead: 1, minutesAgo: 1)
        ])
        #expect(changes.repositories.map(\.name) == ["New", "Alpha", "beta", "Old"])
    }

    @Test func showsAtMostTheLimitButCountsThemAll() {
        let summaries = (0..<8).map { summary("R\($0)", ahead: 1, minutesAgo: Double($0)) }
        let changes = UnpushedChanges(summaries)
        #expect(changes.repositories.map(\.name) == ["R0", "R1", "R2", "R3", "R4"])
        #expect(changes.total == 8)
        #expect(UnpushedChanges(summaries, limit: 2).repositories.count == 2)
    }

    @Test func isEmptyWhenEverythingIsPushed() {
        let changes = UnpushedChanges([summary("Clean", minutesAgo: 1)])
        #expect(changes.isEmpty)
        #expect(changes.repositories.isEmpty)
        #expect(UnpushedChanges([]).isEmpty)
    }

    @Test func describesTheCounts() {
        #expect(summary("A", ahead: 2, minutesAgo: 0).unpushedDescription == "2 unpushed")
        #expect(summary("A", ahead: 1, behind: 3, changes: true, minutesAgo: 0).unpushedDescription
            == "1 unpushed, 3 behind, uncommitted changes")
    }
}

@Suite(.serialized) struct PendingCloneTests {
    @Test func handsAnAddressOverOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwigSharedTests-\(UUID().uuidString)")
        SharedContainer.directoryOverride = folder
        defer {
            SharedContainer.directoryOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(PendingClone.take() == nil)
        try PendingClone.leave("https://example.com/owner/project.git")
        #expect(PendingClone.take() == "https://example.com/owner/project.git")
        #expect(PendingClone.take() == nil)

        // One left long ago is dropped.
        try PendingClone.leave("https://example.com/owner/old.git")
        #expect(PendingClone.take(now: .now.addingTimeInterval(7200)) == nil)
        #expect(PendingClone.take() == nil)
    }
}
