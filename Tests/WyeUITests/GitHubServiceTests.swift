import Foundation
import Testing
@testable import WyeUI

/// GitHub's REST and GraphQL shapes, written from its API documentation.
@Suite struct GitHubServiceTests {
    static let repo = RepositoryPath(owner: "octo", name: "project")

    static let repoJSON = """
    {"id":1,"name":"project","full_name":"octo/project","private":true,"owner":{"login":"octo","id":1},
     "html_url":"https://github.com/octo/project","description":"A project","fork":false,
     "clone_url":"https://github.com/octo/project.git","ssh_url":"git@github.com:octo/project.git",
     "default_branch":"main","visibility":"private","pushed_at":"2024-05-01T10:00:00Z","updated_at":"2024-05-02T10:00:00Z"}
    """

    static let graphPullRequest = """
    {"number":12,"title":"Add login","body":"It **works**.","isDraft":true,"state":"OPEN",
     "createdAt":"2024-05-01T10:00:00Z","updatedAt":"2024-05-03T10:00:00Z","url":"https://github.com/octo/project/pull/12",
     "mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","author":{"login":"mona","avatarUrl":"https://avatars.example/mona"},
     "headRefName":"feature/login","headRefOid":"aaaa","baseRefName":"main","baseRefOid":"bbbb",
     "headRepository":{"nameWithOwner":"mona/project","url":"https://github.com/mona/project","sshUrl":"git@github.com:mona/project.git"},
     "baseRepository":{"nameWithOwner":"octo/project","url":"https://github.com/octo/project","sshUrl":"git@github.com:octo/project.git"},
     "comments":{"totalCount":3},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}
    """

    @Test func readsTheUser() async throws {
        let stub = StubTransport()
        stub.on("GET", "api.github.com/user", json: #"{"login":"octo","id":7,"name":"Octo Cat","avatar_url":"https://avatars.example/o"}"#)
        let user = try await stubService(.github, transport: stub).currentUser()
        #expect(user == HostingUser(login: "octo", name: "Octo Cat", avatarURL: URL(string: "https://avatars.example/o"), serviceID: "7"))
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func enterpriseUsesItsOwnAPI() async throws {
        let stub = StubTransport()
        stub.on("GET", "ghe.example.com/api/v3/user", json: #"{"login":"octo"}"#)
        _ = try await stubService(.github, host: "ghe.example.com", transport: stub).currentUser()
        let service = try #require(stubService(.github, host: "ghe.example.com", transport: stub) as? GitHubService)
        #expect(service.graphQLURL.absoluteString == "https://ghe.example.com/api/graphql")
        let public_ = try #require(stubService(.github, transport: stub) as? GitHubService)
        #expect(public_.graphQLURL.absoluteString == "https://api.github.com/graphql")
    }

    @Test func listsRepositoriesAndFollowsLinks() async throws {
        let stub = StubTransport()
        stub.on("GET", "/user/repos", json: "[\(Self.repoJSON)]", headers: [
            "Link": #"<https://api.github.com/user/repos?page=2>; rel="next", <https://api.github.com/user/repos?page=4>; rel="last""#
        ])
        let service = stubService(.github, transport: stub)
        let page = try await service.repositories(.member, query: "", page: nil)
        let repository = try #require(page.items.first)
        #expect(repository.path.fullPath == "octo/project")
        #expect(repository.isPrivate)
        #expect(repository.defaultBranch == "main")
        #expect(repository.cloneURL(preferSSH: true) == "git@github.com:octo/project.git")
        #expect(repository.cloneURL(preferSSH: false) == "https://github.com/octo/project.git")
        #expect(page.next == .url(URL(string: "https://api.github.com/user/repos?page=2")!))
        let request = try #require(stub.last("GET", "/user/repos"))
        #expect(request.query("affiliation") == "owner,collaborator,organization_member")
    }

    @Test func searchCoversTheAccountAndItsOrganizations() async throws {
        let stub = StubTransport()
        stub.on("GET", "api.github.com/user/orgs", json: #"[{"login":"team"}]"#)
        stub.on("GET", "api.github.com/user?", json: #"{"login":"octo"}"#)
        stub.on("GET", "api.github.com/user", json: #"{"login":"octo"}"#)
        stub.on("GET", "/search/repositories", json: #"{"total_count":1,"items":[\#(Self.repoJSON)]}"#)
        let page = try await stubService(.github, transport: stub).repositories(.member, query: "proj", page: nil)
        #expect(page.items.count == 1)
        #expect(stub.last("GET", "/search/repositories")?.query("q") == "proj in:name fork:true user:octo org:team")
    }

    @Test func createsInAnOrganization() async throws {
        let stub = StubTransport()
        stub.on("POST", "/orgs/team/repos", status: 201, json: Self.repoJSON)
        let draft = NewRepositoryDraft(
            owner: HostingOwner(login: "team", displayName: "team", isUser: false), name: "project",
            description: "A project", isPrivate: true
        )
        let created = try await stubService(.github, transport: stub).createRepository(draft)
        #expect(created.httpsURL == "https://github.com/octo/project.git")
        let body = try #require(stub.last("POST", "/orgs/team/repos")?.jsonBody)
        #expect(body["name"] as? String == "project")
        #expect(body["private"] as? Bool == true)
    }

    @Test func listsPullRequestsThroughSearch() async throws {
        let stub = StubTransport()
        stub.on("POST", "/graphql", json: """
        {"data":{"search":{"pageInfo":{"hasNextPage":true,"endCursor":"Y3Vy"},"nodes":[\(Self.graphPullRequest),{}]}}}
        """)
        let page = try await stubService(.github, transport: stub)
            .pullRequests(in: Self.repo, filter: .reviewRequested, page: .token("abc"))
        let pr = try #require(page.items.first)
        #expect(page.items.count == 1)
        #expect(page.next == .token("Y3Vy"))
        #expect(pr.number == 12)
        #expect(pr.isDraft)
        #expect(pr.state == .open)
        #expect(pr.checks == .failure)
        #expect(pr.review == .changesRequested)
        #expect(pr.isMergeable == true)
        #expect(pr.commentCount == 3)
        #expect(pr.head.name == "feature/login")
        #expect(pr.head.repository?.httpsURL == "https://github.com/mona/project.git")
        #expect(pr.isFromOtherRepository)
        #expect(pr.author?.login == "mona")
        let variables = try #require(stub.last("POST", "/graphql")?.jsonBody?["variables"] as? [String: Any])
        #expect(variables["q"] as? String == "repo:octo/project is:pr is:open review-requested:@me sort:updated-desc")
        #expect(variables["after"] as? String == "abc")
    }

    @Test func graphQLErrorsMap() async throws {
        let stub = StubTransport()
        stub.on("POST", "/graphql", json: #"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#)
        await #expect(throws: HostingError.rateLimited(host: "github.com", reset: nil)) {
            _ = try await stubService(.github, transport: stub).pullRequest(in: Self.repo, number: 1)
        }
    }

    @Test func readsTheConversationInOrder() async throws {
        let stub = StubTransport()
        stub.on("GET", "/issues/12/comments", json: """
        [{"id":1,"user":{"login":"mona"},"body":"First","created_at":"2024-05-01T10:00:00Z"}]
        """)
        stub.on("GET", "/pulls/12/reviews", json: """
        [{"id":2,"user":{"login":"octo"},"body":"","state":"APPROVED","submitted_at":"2024-05-03T10:00:00Z"},
         {"id":3,"user":{"login":"octo"},"body":"","state":"COMMENTED","submitted_at":"2024-05-02T10:00:00Z"},
         {"id":4,"user":{"login":"octo"},"body":"draft","state":"PENDING"}]
        """)
        stub.on("GET", "/pulls/12/comments", json: """
        [{"id":5,"user":{"login":"octo"},"body":"Nit","created_at":"2024-05-02T11:00:00Z","path":"a.swift","line":4}]
        """)
        let items = try await stubService(.github, transport: stub).conversation(in: Self.repo, number: 12)
        #expect(items.map(\.id) == ["c1", "l5", "r2"])
        #expect(items[1].kind == .lineComment(path: "a.swift", line: 4))
        #expect(items[2].kind == .review(.approve))
    }

    @Test func readsCommitsAndFilesAcrossPages() async throws {
        let stub = StubTransport()
        stub.on("GET", "/pulls/12/commits?per_page=100", json: """
        [{"sha":"a1","commit":{"message":"Add login\\n\\nBody","author":{"name":"Mona","date":"2024-05-01T10:00:00Z"}}}]
        """, headers: ["Link": #"<https://api.github.com/repos/octo/project/pulls/12/commits?page=2>; rel="next""#])
        stub.on("GET", "/pulls/12/commits?page=2", json: #"[{"sha":"a2","commit":{"message":"Fix"}}]"#)
        stub.on("GET", "/pulls/12/files", json: """
        [{"filename":"b.swift","status":"renamed","previous_filename":"a.swift","additions":1,"deletions":2},
         {"filename":"c.swift","status":"removed"}]
        """)
        let service = stubService(.github, transport: stub)
        let commits = try await service.commits(in: Self.repo, number: 12)
        #expect(commits.map(\.sha) == ["a1", "a2"])
        #expect(commits[0].subject == "Add login")
        let files = try await service.changedFiles(in: Self.repo, number: 12)
        #expect(files[0].status == .renamed)
        #expect(files[0].previousPath == "a.swift")
        #expect(files[1].status == .deleted)
    }

    @Test func writesReviewsMergesAndState() async throws {
        let stub = StubTransport()
        stub.on("POST", "/pulls/12/reviews", json: "{}")
        stub.on("PUT", "/pulls/12/merge", json: #"{"merged":true}"#)
        stub.on("PATCH", "/pulls/12", json: "{}")
        stub.on("POST", "/issues/12/comments", status: 201, json: "{}")
        let service = stubService(.github, transport: stub)
        try await service.review(.requestChanges, body: "Please fix", in: Self.repo, number: 12)
        #expect(stub.last("POST", "/reviews")?.jsonBody?["event"] as? String == "REQUEST_CHANGES")
        try await service.merge(in: Self.repo, number: 12, method: .squash, expectedHead: "aaaa")
        let merge = try #require(stub.last("PUT", "/merge")?.jsonBody)
        #expect(merge["merge_method"] as? String == "squash")
        #expect(merge["sha"] as? String == "aaaa")
        try await service.setOpen(false, in: Self.repo, number: 12)
        #expect(stub.last("PATCH", "/pulls/12")?.jsonBody?["state"] as? String == "closed")
        try await service.addComment("Thanks", in: Self.repo, number: 12)
        #expect(stub.last("POST", "/issues/12/comments")?.jsonBody?["body"] as? String == "Thanks")
    }

    @Test func mergeConflictIsSaidPlainly() async throws {
        let stub = StubTransport()
        stub.on("PUT", "/pulls/12/merge", status: 405, json: #"{"message":"Pull Request is not mergeable"}"#)
        await #expect(throws: HostingError.rejected(message: "Pull Request is not mergeable")) {
            try await stubService(.github, transport: stub).merge(in: Self.repo, number: 12, method: .merge, expectedHead: nil)
        }
    }

    @Test func createsAPullRequestFromAnotherOwner() async throws {
        let stub = StubTransport()
        stub.on("POST", "/repos/octo/project/pulls", status: 201, json: """
        {"number":13,"title":"T","body":null,"state":"open","draft":true,"user":{"login":"mona"},
         "head":{"ref":"topic","sha":"aaaa","repo":{"full_name":"mona/project","clone_url":"https://github.com/mona/project.git"}},
         "base":{"ref":"main","sha":"bbbb","repo":{"full_name":"octo/project"}},
         "created_at":"2024-05-01T10:00:00Z","updated_at":"2024-05-01T10:00:00Z","html_url":"https://github.com/octo/project/pull/13"}
        """)
        let draft = NewPullRequestDraft(base: "main", head: "topic", headOwner: "mona", title: "T", body: "", isDraft: true)
        let pr = try await stubService(.github, transport: stub).createPullRequest(draft, in: Self.repo)
        #expect(pr.number == 13)
        #expect(pr.isDraft)
        #expect(pr.isFromOtherRepository)
        #expect(stub.last("POST", "/pulls")?.jsonBody?["head"] as? String == "mona:topic")
    }

    @Test func mergedRESTPullRequestReadsAsMerged() throws {
        let json = """
        {"number":1,"title":"T","state":"closed","merged_at":"2024-05-01T10:00:00Z",
         "head":{"ref":"a"},"base":{"ref":"b"}}
        """
        let pr = try HostingClient.decoder.decode(GitHubService.RESTPullRequest.self, from: Data(json.utf8)).pullRequest
        #expect(pr.state == .merged)
    }
}
