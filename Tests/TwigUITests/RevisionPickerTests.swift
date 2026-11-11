import Foundation
import GitKit
import Testing
@testable import TwigUI

/// What the revision picker offers for what is typed, and the names the
/// context menus give archives.
@Suite struct RevisionPickerTests {
    private let commit = OID(hex: "0123456789abcdef0123456789abcdef01234567")!

    private var snapshot: RepositorySnapshot {
        RepositorySnapshot(
            head: .branch(name: "refs/heads/main", target: commit),
            branches: [
                Branch(id: "refs/heads/feature/login", name: "feature/login", target: commit),
                Branch(id: "refs/heads/main", name: "main", target: commit, isHead: true)
            ],
            remotes: [Remote(name: "origin", url: nil, branches: [
                Branch(id: "refs/remotes/origin/HEAD", name: "origin/HEAD", target: commit, isRemote: true),
                Branch(id: "refs/remotes/origin/main", name: "origin/main", target: commit, isRemote: true)
            ])],
            tags: [Tag(id: "refs/tags/v1.0", name: "v1.0", target: commit)]
        )
    }

    @Test func offersHeadBranchesRemoteBranchesAndTags() {
        let choices = RevisionChoice.choices(in: snapshot)
        #expect(choices.map(\.revision) == [
            "HEAD", "refs/heads/feature/login", "refs/heads/main", "refs/remotes/origin/main", "refs/tags/v1.0"
        ])
        #expect(choices.map(\.kind) == [.head, .branch, .branch, .remoteBranch, .tag])
        #expect(RevisionChoice.choices(in: nil).isEmpty)
    }

    @Test func nothingTypedListsEverything() {
        let choices = RevisionChoice.choices(in: snapshot)
        #expect(RevisionChoice.matching("  ", in: choices) == choices)
    }

    @Test func anExactNameNeedsNoTypedRow() {
        let matches = RevisionChoice.matching("main", in: RevisionChoice.choices(in: snapshot))
        // The shorter name first among equal matches, and no "Use “main”".
        #expect(matches.map(\.title) == ["main", "origin/main"])
    }

    @Test func otherTextIsOfferedAsARevisionAfterTheMatches() {
        let matches = RevisionChoice.matching("login", in: RevisionChoice.choices(in: snapshot))
        #expect(matches.map(\.title) == ["feature/login", "login"])
        #expect(matches.last?.kind == .typed)

        let hash = RevisionChoice.matching(" HEAD~2 ", in: RevisionChoice.choices(in: snapshot))
        #expect(hash.last == RevisionChoice(kind: .typed, revision: "HEAD~2", title: "HEAD~2", detail: "Revision"))
    }

    @Test func theCompareFieldGetsShortNames() {
        let choices = RevisionChoice.choices(in: snapshot)
        #expect(choices.map(\.compareName) == ["HEAD", "feature/login", "main", "origin/main", "v1.0"])
    }

    @MainActor
    @Test func archiveNamesHaveNoSlashes() {
        #expect(RepositoryModel.archiveName(repository: "twig", revision: "feature/login") == "twig-feature-login")
        #expect(RepositoryModel.archiveName(repository: "twig", revision: "v1.0") == "twig-v1.0")
    }
}
