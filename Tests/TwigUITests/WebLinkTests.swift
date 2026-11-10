import Foundation
import GitKit
import Testing
@testable import TwigUI

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
