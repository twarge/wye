import Foundation
import GitKit
import Testing
@testable import WyeUI

@Suite struct WebLinkTests {
    private let commit = OID(hex: "0123456789abcdef0123456789abcdef01234567")!

    @Test func readsHTTPSAndSSHForms() {
        let forms = [
            "https://github.com/owner/project.git",
            "https://user@github.com/owner/project",
            "https://github.com/owner/project/",
            "git@github.com:owner/project.git",
            "ssh://git@github.com/owner/project.git",
            "ssh://git@github.com:2222/owner/project.git"
        ]
        for form in forms {
            #expect(HostedRepository(remoteURL: form)?.url.absoluteString == "https://github.com/owner/project", "\(form)")
        }
        #expect(HostedRepository(remoteURL: "http://git.example.com:3000/team/app.git")?.url.absoluteString
            == "http://git.example.com:3000/team/app")
    }

    @Test func localPathsHaveNoPage() {
        #expect(HostedRepository(remoteURL: "../project.git") == nil)
        #expect(HostedRepository(remoteURL: "/srv/git/project.git") == nil)
        #expect(HostedRepository(remoteURL: "file:///srv/git/project.git") == nil)
        #expect(HostedRepository(remoteURL: "C:/project") == nil)
    }

    @Test func branchAndCommitPagesFollowTheHost() throws {
        let github = try #require(HostedRepository(remoteURL: "git@github.com:owner/project.git"))
        #expect(github.url(forBranch: "feature/one")?.absoluteString == "https://github.com/owner/project/tree/feature/one")
        #expect(github.url(forCommit: commit)?.absoluteString == "https://github.com/owner/project/commit/\(commit.hex)")

        let gitlab = try #require(HostedRepository(remoteURL: "https://gitlab.com/group/sub/project.git"))
        #expect(gitlab.url(forBranch: "main")?.absoluteString == "https://gitlab.com/group/sub/project/-/tree/main")
        #expect(gitlab.url(forCommit: commit)?.absoluteString == "https://gitlab.com/group/sub/project/-/commit/\(commit.hex)")

        let bitbucket = try #require(HostedRepository(remoteURL: "https://bitbucket.org/team/project.git"))
        #expect(bitbucket.url(forCommit: commit)?.absoluteString == "https://bitbucket.org/team/project/commits/\(commit.hex)")

        let codeberg = try #require(HostedRepository(remoteURL: "https://codeberg.org/owner/project.git"))
        #expect(codeberg.url(forBranch: "main")?.absoluteString == "https://codeberg.org/owner/project/src/branch/main")

        let unknown = try #require(HostedRepository(remoteURL: "https://git.example.com/project.git"))
        #expect(unknown.url.absoluteString == "https://git.example.com/project")
        #expect(unknown.url(forCommit: commit) == nil)
    }

    @Test func branchNamesAreEncoded() throws {
        let github = try #require(HostedRepository(remoteURL: "https://github.com/owner/project"))
        #expect(github.url(forBranch: "fix #1 é")?.absoluteString == "https://github.com/owner/project/tree/fix%20%231%20%C3%A9")
    }
}

/// The pages that start a pull request, or a merge request on GitLab.
@Suite struct PullRequestLinkTests {
    private func link(_ remote: String, _ branch: String, into base: String? = nil) -> String? {
        HostedRepository(remoteURL: remote)?.newPullRequestURL(forBranch: branch, into: base)?.absoluteString
    }

    @Test func eachHostsNewPullRequestPage() {
        #expect(link("git@github.com:owner/project.git", "feature/login", into: "main")
            == "https://github.com/owner/project/compare/main...feature/login?expand=1")
        #expect(link("https://github.com/owner/project", "topic")
            == "https://github.com/owner/project/compare/topic?expand=1")
        #expect(link("https://gitlab.com/group/project.git", "feature/login", into: "main")
            == "https://gitlab.com/group/project/-/merge_requests/new?merge_request%5Bsource_branch%5D=feature%2Flogin"
                + "&merge_request%5Btarget_branch%5D=main")
        #expect(link("git@bitbucket.org:team/project.git", "topic", into: "main")
            == "https://bitbucket.org/team/project/pull-requests/new?source=topic&dest=main")
        #expect(link("https://codeberg.org/owner/project.git", "topic", into: "main")
            == "https://codeberg.org/owner/project/compare/main...topic")
    }

    @Test func namesAreEncoded() {
        #expect(link("https://github.com/owner/project", "fix #12 & more")
            == "https://github.com/owner/project/compare/fix%20%2312%20&%20more?expand=1")
        #expect(link("https://gitlab.com/owner/project", "a&b=c")
            == "https://gitlab.com/owner/project/-/merge_requests/new?merge_request%5Bsource_branch%5D=a%26b%3Dc")
    }

    @Test func hostsWithoutPullRequestsHaveNoPage() {
        #expect(link("https://git.sr.ht/~owner/project", "topic") == nil)
        #expect(link("https://git.example.com/owner/project", "topic") == nil)
    }
}
