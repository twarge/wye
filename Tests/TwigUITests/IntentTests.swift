import Foundation
import GitKit
import Testing
@testable import TwigUI

@Suite struct RepositoryMatchingTests {
    let names = ["Horizontal", "horizontal-app", "Twig", "Notes", "MyHorizontalTools", "Ångström", "TwigDocs"]

    func match(_ query: String) -> [String] {
        RepositoryMatching.matches(query, in: names, name: \.self)
    }

    @Test func putsTheSameNameFirst() {
        #expect(match("Horizontal") == ["Horizontal", "horizontal-app", "MyHorizontalTools"])
        #expect(match("horizontal").first == "Horizontal")
    }

    @Test func ignoresSpacesPunctuationAndCase() {
        #expect(match("Horizontal App") == ["horizontal-app"])
        #expect(match("HORIZONTAL-APP") == ["horizontal-app"])
    }

    @Test func ignoresAccents() {
        #expect(match("angstrom") == ["Ångström"])
    }

    @Test func ranksStartsBeforeWordsBeforeContains() {
        // "Twig" is the name; "TwigDocs" starts with it.
        #expect(match("twig") == ["Twig", "TwigDocs"])
        // "tools" starts a word in "MyHorizontalTools" only.
        #expect(match("tools") == ["MyHorizontalTools"])
        // "zont" is only inside names.
        #expect(match("zont") == ["Horizontal", "horizontal-app", "MyHorizontalTools"])
    }

    @Test func matchesNothingForNothing() {
        #expect(match("").isEmpty)
        #expect(match("  -- ").isEmpty)
        #expect(match("payroll").isEmpty)
    }

    @Test func keepsTwoOfTheSameNameInTheirOrder() {
        let items = [(1, "Notes"), (2, "notes")]
        #expect(RepositoryMatching.matches("notes", in: items, name: \.1).map(\.0).count == 2)
    }
}

@Suite struct IntentPhrasingTests {
    let commit = OID(hex: String(repeating: "a", count: 40))!

    @Test func saysWhatAPullDid() {
        #expect(IntentPhrasing.pulled(PullOutcome(result: .upToDate, autostash: .notNeeded), count: 0, branch: "main")
            == "Already up to date.")
        #expect(IntentPhrasing.pulled(PullOutcome(result: .fastForwarded(to: commit), autostash: .notNeeded), count: 3, branch: "main")
            == "Pulled 3 commits into main.")
        #expect(IntentPhrasing.pulled(PullOutcome(result: .fastForwarded(to: commit), autostash: .restored), count: 1, branch: "main")
            == "Pulled 1 commit into main.")
        // The merge commit is not one of the commits pulled.
        #expect(IntentPhrasing.pulled(PullOutcome(result: .merged(commit: commit), autostash: .notNeeded), count: 3, branch: "dev")
            == "Merged 2 commits into dev.")
    }

    @Test func saysToOpenTwigForConflicts() {
        let message = IntentPhrasing.pulled(
            PullOutcome(result: .conflicts(paths: ["a", "b"]), autostash: .keptForLater(stash: commit)),
            count: 0, branch: "main"
        )
        #expect(message == "The pull into main stopped on conflicts in 2 files. Open Twig to resolve them. Your local changes are kept in a stash.")
    }

    @Test func saysWhereABranchStandsAfterAFetch() {
        func branch(ahead: Int, behind: Int) -> Branch {
            Branch(
                id: "refs/heads/main", name: "main", target: commit, isHead: true,
                upstream: Branch.Upstream(name: "origin/main", ahead: ahead, behind: behind)
            )
        }
        #expect(IntentPhrasing.fetched("Horizontal", branch: branch(ahead: 0, behind: 0))
            == "Fetched Horizontal. main is up to date.")
        #expect(IntentPhrasing.fetched("Horizontal", branch: branch(ahead: 0, behind: 4))
            == "Fetched Horizontal. main is 4 commits behind origin/main.")
        #expect(IntentPhrasing.fetched("Horizontal", branch: branch(ahead: 1, behind: 0))
            == "Fetched Horizontal. main has 1 commit to push.")
        #expect(IntentPhrasing.fetched("Horizontal", branch: branch(ahead: 2, behind: 3))
            == "Fetched Horizontal. main is 2 ahead and 3 behind origin/main.")
        #expect(IntentPhrasing.fetched("Horizontal", branch: nil) == "Fetched Horizontal.")
    }

    @Test func countsAFetchOfEverything() {
        #expect(IntentPhrasing.fetchedAll(succeeded: 4, failures: []) == "Fetched all 4 repositories.")
        #expect(IntentPhrasing.fetchedAll(succeeded: 1, failures: []) == "Fetched 1 repository.")
        #expect(IntentPhrasing.fetchedAll(succeeded: 0, failures: []) == "There are no repositories with remotes in Twig to fetch.")
        #expect(IntentPhrasing.fetchedAll(succeeded: 2, failures: ["A failed.", "B failed."])
            == "Fetched 2 of 4 repositories. A failed. 1 more could not be fetched either.")
    }

    @Test func saysWhatAPushDid() {
        #expect(IntentPhrasing.pushed(PushResult(remote: "origin", reference: "refs/heads/main", setUpstream: false), branch: "main", count: 2)
            == "Pushed 2 commits to origin/main.")
        #expect(IntentPhrasing.pushed(PushResult(remote: "origin", reference: "refs/heads/topic", setUpstream: true), branch: "topic", count: 0)
            == "Published topic to origin.")
        #expect(IntentPhrasing.nothingToPush(branch: "main") == "main has nothing to push.")
    }

    @Test func summarisesAStatus() {
        #expect(IntentPhrasing.status("Horizontal", branch: "main", upstream: .init(name: "origin/main", ahead: 0, behind: 0), changedFiles: 0)
            == "Horizontal is on main, up to date, with no changes.")
        #expect(IntentPhrasing.status("Horizontal", branch: "main", upstream: .init(name: "origin/main", ahead: 2, behind: 1), changedFiles: 3)
            == "Horizontal is on main, 2 ahead and 1 behind, with 3 files changed.")
        #expect(IntentPhrasing.status("Horizontal", branch: "topic", upstream: nil, changedFiles: 1)
            == "Horizontal is on topic, not published, with 1 file changed.")
        #expect(IntentPhrasing.status("Horizontal", branch: nil, upstream: nil, changedFiles: 0)
            == "Horizontal is not on a branch, with no changes.")
    }

    @Test func saysToOpenTwigInsteadOfAsking() {
        let required = IntentPhrasing.failure(RemoteError.credentialsRequired(host: "example.com", username: nil), name: "Horizontal")
        #expect(required.contains("example.com") && required.contains("Open Twig"))
        let rejected = IntentPhrasing.failure(RemoteError.credentialsRejected(host: "example.com", username: "me"), name: "Horizontal")
        #expect(rejected.contains("Open Twig"))
        let ssh = IntentPhrasing.failure(RemoteError.sshKeyRequired(host: "example.com", username: "git"), name: "Horizontal")
        #expect(ssh.contains("Open Twig"))
        #expect(IntentPhrasing.failure(RemoteError.noUpstream(branch: "topic"), name: "Horizontal")
            == "Horizontal: “topic” has no upstream branch to pull from. Push it first to publish it.")
    }

    @Test func saysWhenTwigIsBusy() {
        #expect(IntentPhrasing.busy("Horizontal", activity: "Pulling")
            == "Twig is already busy with Horizontal (pulling). Try again when it finishes.")
    }
}
