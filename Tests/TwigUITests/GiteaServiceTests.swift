import Foundation
import Testing
@testable import TwigUI

/// Gitea and Forgejo shapes, written from the v1 API's swagger.
@Suite struct GiteaServiceTests {
    static let repo = RepositoryPath(owner: "owner", name: "project")
    static let me = HostingUser(login: "octo", serviceID: "7")

    private func service(_ stub: StubTransport, user: HostingUser? = me) -> any HostingService {
        stubService(.gitea, user: user, transport: stub, authorization: .token("secret"))
    }

    static let repoJSON = """
    {"id":3,"owner":{"id":7,"login":"owner","full_name":""},"name":"project","full_name":"owner/project",
     "description":"","empty":false,"private":false,"fork":false,"html_url":"https://codeberg.org/owner/project",
     "ssh_url":"git@codeberg.org:owner/project.git","clone_url":"https://codeberg.org/owner/project.git",
     "default_branch":"main","updated_at":"2024-05-02T10:00:00+02:00"}
    """

    static func pullJSON(number: Int = 5, state: String = "open", merged: Bool = false, title: String = "Add login",
                         author: String = "mona", reviewers: String = "[]", draft: String = "") -> String {
        """
        {"id":100,"number":\(number),"title":"\(title)","body":"Body","state":"\(state)","merged":\(merged),
         \(draft)"user":{"id":9,"login":"\(author)","full_name":"Mona","avatar_url":"https://codeberg.org/avatars/m"},
         "head":{"label":"topic","ref":"topic","sha":"aaaa","repo":{"full_name":"mona/project",
           "clone_url":"https://codeberg.org/mona/project.git","ssh_url":"git@codeberg.org:mona/project.git"}},
         "base":{"label":"main","ref":"main","sha":"bbbb","repo":{"full_name":"owner/project",
           "clone_url":"https://codeberg.org/owner/project.git"}},
         "mergeable":true,"comments":2,"requested_reviewers":\(reviewers),
         "html_url":"https://codeberg.org/owner/project/pulls/\(number)",
         "created_at":"2024-05-01T10:00:00Z","updated_at":"2024-05-03T10:00:00Z"}
        """
    }

    @Test func readsTheUserWithATokenHeader() async throws {
        let stub = StubTransport()
        stub.on("GET", "codeberg.org/api/v1/user", json: #"{"id":7,"login":"octo","full_name":"Octo","avatar_url":"https://codeberg.org/a"}"#)
        let user = try await service(stub).currentUser()
        #expect(user == HostingUser(login: "octo", name: "Octo", avatarURL: URL(string: "https://codeberg.org/a"), serviceID: "7"))
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") == "token secret")
    }

    @Test func selfHostedUsesItsOwnHost() async throws {
        let stub = StubTransport()
        stub.on("GET", "git.example.com/api/v1/user", json: #"{"login":"octo"}"#)
        _ = try await stubService(.gitea, host: "git.example.com", transport: stub, authorization: .token("t")).currentUser()
        #expect(stub.requests.count == 1)
    }

    @Test func listsRepositoriesFollowingLinks() async throws {
        let stub = StubTransport()
        stub.on("GET", "/user/repos", json: "[\(Self.repoJSON)]", headers: [
            "Link": #"<https://codeberg.org/api/v1/user/repos?limit=30&page=2>; rel="next""#
        ])
        let page = try await service(stub).repositories(.member, query: "", page: nil)
        let repository = try #require(page.items.first)
        #expect(repository.path.fullPath == "owner/project")
        #expect(repository.description == nil)
        #expect(!repository.isPrivate)
        #expect(repository.defaultBranch == "main")
        #expect(repository.cloneURL(preferSSH: true) == "git@codeberg.org:owner/project.git")
        #expect(page.next == .url(URL(string: "https://codeberg.org/api/v1/user/repos?limit=30&page=2")!))
        #expect(stub.last("GET", "/user/repos")?.query("limit") == "30")
    }

    @Test func fullPagesWithoutLinksGoOnByNumber() async throws {
        let stub = StubTransport()
        let thirty = Array(repeating: Self.repoJSON, count: 30).joined(separator: ",")
        stub.on("GET", "/user/starred", json: "[\(thirty)]")
        let page = try await service(stub).repositories(.starred, query: "", page: .number(2))
        #expect(page.items.count == 30)
        #expect(page.next == .number(3))
        #expect(stub.last("GET", "/user/starred")?.query("page") == "2")
    }

    @Test func searchesWithTheUsersID() async throws {
        let stub = StubTransport()
        stub.on("GET", "/repos/search", json: #"{"ok":true,"data":[\#(Self.repoJSON)]}"#)
        let page = try await service(stub).repositories(.member, query: "proj", page: nil)
        #expect(page.items.count == 1)
        #expect(page.next == nil)
        let request = try #require(stub.last("GET", "/repos/search"))
        #expect(request.query("q") == "proj")
        #expect(request.query("uid") == "7")
        #expect(request.query("sort") == "updated")
    }

    @Test func ownersAndCreation() async throws {
        let stub = StubTransport()
        stub.on("GET", "/user/orgs", json: #"[{"id":1,"username":"team","name":"team","full_name":"The Team"}]"#)
        stub.on("GET", "/api/v1/user", json: #"{"login":"octo","full_name":"Octo"}"#)
        stub.on("POST", "/orgs/team/repos", status: 201, json: Self.repoJSON)
        let service = service(stub)
        let owners = try await service.owners()
        #expect(owners.map(\.login) == ["octo", "team"])
        #expect(owners[1].displayName == "The Team")
        #expect(owners[0].isUser)
        let created = try await service.createRepository(
            NewRepositoryDraft(owner: owners[1], name: "project", description: "D", isPrivate: true)
        )
        #expect(created.httpsURL == "https://codeberg.org/owner/project.git")
        let body = try #require(stub.last("POST", "/orgs/team/repos")?.jsonBody)
        #expect(body["private"] as? Bool == true)
        #expect(body["description"] as? String == "D")
    }

    @Test func listsOpenPullRequests() async throws {
        let stub = StubTransport()
        stub.on("GET", "/repos/owner/project/pulls", json: "[\(Self.pullJSON(title: "WIP: Add login"))]")
        let page = try await service(stub).pullRequests(in: Self.repo, filter: .open, page: nil)
        let pr = try #require(page.items.first)
        #expect(pr.number == 5)
        #expect(pr.state == .open)
        #expect(pr.isDraft)
        #expect(pr.author?.displayName == "Mona")
        #expect(pr.head == PullRequestBranch(name: "topic", sha: "aaaa", repository: RepositoryReference(
            path: RepositoryPath(owner: "mona", name: "project"),
            httpsURL: "https://codeberg.org/mona/project.git", sshURL: "git@codeberg.org:mona/project.git"
        )))
        #expect(pr.isFromOtherRepository)
        #expect(pr.commentCount == 2)
        #expect(pr.isMergeable == true)
        #expect(page.next == nil)
        let request = try #require(stub.last("GET", "/pulls"))
        #expect(request.query("state") == "open")
        #expect(request.query("sort") == "recentupdate")
        #expect(request.query("poster") == nil)
    }

    @Test func narrowsClosedMergedMineAndReviewRequested() async throws {
        let stub = StubTransport()
        stub.on("GET", "state=closed", json: "[\(Self.pullJSON(number: 1, state: "closed", merged: true)),\(Self.pullJSON(number: 2, state: "closed"))]")
        stub.on("GET", "state=open", json: """
        [\(Self.pullJSON(number: 3, author: "octo")),
         \(Self.pullJSON(number: 4, reviewers: #"[{"login":"octo"}]"#, draft: #""draft":false,"#))]
        """)
        let service = service(stub)
        let merged = try await service.pullRequests(in: Self.repo, filter: .merged, page: nil).items
        #expect(merged.map(\.number) == [1])
        #expect(merged.first?.state == .merged)
        #expect(merged.first?.isMergeable == nil)
        #expect(try await service.pullRequests(in: Self.repo, filter: .closed, page: nil).items.map(\.number) == [2])
        #expect(try await service.pullRequests(in: Self.repo, filter: .mine, page: nil).items.map(\.number) == [3])
        #expect(stub.last("GET", "/pulls")?.query("poster") == "octo")
        let requested = try await service.pullRequests(in: Self.repo, filter: .reviewRequested, page: nil).items
        #expect(requested.map(\.number) == [4])
        #expect(requested.first?.isDraft == false)
    }

    @Test func detailAddsChecksAndReviews() async throws {
        let stub = StubTransport()
        stub.on("GET", "/pulls/5/reviews", json: """
        [{"id":1,"user":{"login":"a"},"state":"REQUEST_CHANGES","body":"No","submitted_at":"2024-05-01T10:00:00Z"},
         {"id":2,"user":{"login":"a"},"state":"APPROVED","body":"","submitted_at":"2024-05-02T10:00:00Z"},
         {"id":3,"user":{"login":"b"},"state":"COMMENT","body":"Hm","submitted_at":"2024-05-02T11:00:00Z"}]
        """)
        stub.on("GET", "/pulls/5", json: Self.pullJSON())
        stub.on("GET", "/commits/aaaa/status", json: #"{"state":"failure","sha":"aaaa","total_count":2,"statuses":[{"status":"success"},{"status":"failure"}]}"#)
        let pr = try await service(stub).pullRequest(in: Self.repo, number: 5)
        #expect(pr.checks == .failure)
        #expect(pr.review == .approved)
    }

    @Test func noStatusesMeansNoChecks() async throws {
        let stub = StubTransport()
        stub.on("GET", "/pulls/5/reviews", json: "[]")
        stub.on("GET", "/pulls/5", json: Self.pullJSON())
        stub.on("GET", "/commits/aaaa/status", json: #"{"state":"","total_count":0,"statuses":[]}"#)
        let pr = try await service(stub).pullRequest(in: Self.repo, number: 5)
        #expect(pr.checks == nil)
        #expect(pr.review == nil)
    }

    @Test func readsCommitsFilesAndConversation() async throws {
        let stub = StubTransport()
        stub.on("GET", "/pulls/5/commits", json: """
        [{"sha":"a1","created":"2024-05-01T10:00:00Z","commit":{"message":"Add login\\n\\nMore","author":{"name":"Mona","date":"2024-05-01T10:00:00Z"}}}]
        """)
        stub.on("GET", "/pulls/5/files", json: """
        [{"filename":"b.swift","status":"renamed","previous_filename":"a.swift","additions":1,"deletions":0,"changes":1},
         {"filename":"c.swift","status":"deleted","previous_filename":""},
         {"filename":"d.swift","status":"changed"}]
        """)
        stub.on("GET", "/issues/5/comments", json: """
        [{"id":11,"user":{"login":"mona"},"body":"First","created_at":"2024-05-01T10:00:00Z"}]
        """)
        stub.on("GET", "/pulls/5/reviews", json: """
        [{"id":2,"user":{"login":"octo"},"state":"APPROVED","body":"LGTM","submitted_at":"2024-05-02T10:00:00Z"},
         {"id":3,"user":{"login":"octo"},"state":"PENDING","body":"draft"},
         {"id":4,"user":{"login":"octo"},"state":"COMMENT","body":"","submitted_at":"2024-05-02T10:00:00Z"}]
        """)
        let service = service(stub)
        let commits = try await service.commits(in: Self.repo, number: 5)
        #expect(commits.map(\.subject) == ["Add login"])
        #expect(commits.first?.authorName == "Mona")
        #expect(stub.last("GET", "/pulls/5/commits")?.query("limit") == "50")
        let files = try await service.changedFiles(in: Self.repo, number: 5)
        #expect(files.map(\.status) == [.renamed, .deleted, .modified])
        #expect(files[0].previousPath == "a.swift")
        #expect(files[1].previousPath == nil)
        let conversation = try await service.conversation(in: Self.repo, number: 5)
        #expect(conversation.map(\.id) == ["c11", "r2"])
        #expect(conversation[1].kind == .review(.approve))
    }

    @Test func writesCommentsReviewsMergesAndState() async throws {
        let stub = StubTransport()
        stub.on("POST", "/issues/5/comments", status: 201, json: "{}")
        stub.on("POST", "/pulls/5/reviews", json: "{}")
        stub.on("POST", "/pulls/5/merge", json: "")
        stub.on("PATCH", "/pulls/5", status: 201, json: Self.pullJSON())
        let service = service(stub)
        try await service.addComment("Thanks", in: Self.repo, number: 5)
        #expect(stub.last("POST", "/comments")?.jsonBody?["body"] as? String == "Thanks")
        try await service.review(.approve, body: "", in: Self.repo, number: 5)
        #expect(stub.last("POST", "/reviews")?.jsonBody?["event"] as? String == "APPROVED")
        try await service.review(.requestChanges, body: "Fix", in: Self.repo, number: 5)
        #expect(stub.last("POST", "/reviews")?.jsonBody?["event"] as? String == "REQUEST_CHANGES")
        try await service.merge(in: Self.repo, number: 5, method: .squash, expectedHead: "aaaa")
        let merge = try #require(stub.last("POST", "/merge")?.jsonBody)
        #expect(merge["Do"] as? String == "squash")
        #expect(merge["head_commit_id"] as? String == "aaaa")
        try await service.setOpen(true, in: Self.repo, number: 5)
        #expect(stub.last("PATCH", "/pulls/5")?.jsonBody?["state"] as? String == "open")
    }

    @Test func createsADraftFromAnotherOwner() async throws {
        let stub = StubTransport()
        stub.on("POST", "/repos/owner/project/pulls", status: 201, json: Self.pullJSON(title: "WIP: Add login"))
        let draft = NewPullRequestDraft(base: "main", head: "topic", headOwner: "mona", title: "Add login", body: "B", isDraft: true)
        let pr = try await service(stub).createPullRequest(draft, in: Self.repo)
        #expect(pr.isDraft)
        let body = try #require(stub.last("POST", "/pulls")?.jsonBody)
        #expect(body["title"] as? String == "WIP: Add login")
        #expect(body["head"] as? String == "mona:topic")
        #expect(body["base"] as? String == "main")
        #expect(service(stub).headReference(number: 5) == "refs/pull/5/head")
    }

    @Test func errorsMap() async throws {
        let stub = StubTransport()
        stub.on("POST", "/pulls/1/merge", status: 405, json: #"{"message":"Please try again later","url":"https://codeberg.org/api/swagger"}"#)
        stub.on("POST", "/pulls/2/merge", status: 409, json: #"{"message":"head out of date","url":"https://codeberg.org/api/swagger"}"#)
        stub.on("POST", "/pulls", status: 422, json: #"{"message":"pull request already exists for these targets","url":"x"}"#)
        stub.on("PATCH", "/pulls/3", status: 403, json: #"{"message":"token does not have at least one of required scope(s): [write:issue]","url":"x"}"#)
        let service = service(stub)
        await #expect(throws: HostingError.rejected(message: "Please try again later")) {
            try await service.merge(in: Self.repo, number: 1, method: .merge, expectedHead: nil)
        }
        await #expect(throws: HostingError.rejected(message: "head out of date")) {
            try await service.merge(in: Self.repo, number: 2, method: .rebase, expectedHead: nil)
        }
        await #expect(throws: HostingError.rejected(message: "pull request already exists for these targets")) {
            _ = try await service.createPullRequest(
                NewPullRequestDraft(base: "main", head: "topic", title: "T", body: "", isDraft: false), in: Self.repo
            )
        }
        await #expect(throws: HostingError.forbidden(host: "codeberg.org", message: "token does not have at least one of required scope(s): [write:issue]")) {
            try await service.setOpen(false, in: Self.repo, number: 3)
        }
        await #expect(throws: HostingError.notFound(host: "codeberg.org")) {
            _ = try await service.pullRequest(in: Self.repo, number: 99)
        }
    }
}
