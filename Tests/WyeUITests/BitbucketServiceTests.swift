import Foundation
import Testing
@testable import WyeUI

/// Bitbucket Cloud's API 2.0 shapes, written from its documentation.
@Suite struct BitbucketServiceTests {
    static let repo = RepositoryPath(owner: "team", name: "project")
    static let me = HostingUser(login: "mona", name: "Mona", serviceID: "{1111-2222}")

    static let repoJSON = """
    {"type":"repository","full_name":"team/project","name":"project","description":"A project","is_private":true,
     "mainbranch":{"type":"branch","name":"main"},"updated_on":"2024-05-02T10:00:00.123456+00:00",
     "links":{"html":{"href":"https://bitbucket.org/team/project"},
       "clone":[{"name":"https","href":"https://mona@bitbucket.org/team/project.git"},
                {"name":"ssh","href":"git@bitbucket.org:team/project.git"}]}}
    """

    static let pullRequestJSON = """
    {"type":"pullrequest","id":7,"title":"Add login","description":"It **works**.","state":"OPEN","draft":true,
     "author":{"display_name":"Mona","nickname":"mona","uuid":"{1111-2222}","links":{"avatar":{"href":"https://avatar.example/m"}}},
     "source":{"branch":{"name":"feature/login"},"commit":{"hash":"aaaaaaaaaaaa"},"repository":{"full_name":"mona/project"}},
     "destination":{"branch":{"name":"main"},"commit":{"hash":"bbbbbbbbbbbb"},"repository":{"full_name":"team/project"}},
     "created_on":"2024-05-01T10:00:00.000000+00:00","updated_on":"2024-05-03T10:00:00.654321+00:00",
     "links":{"html":{"href":"https://bitbucket.org/team/project/pull-requests/7"}},"comment_count":2,
     "participants":[{"role":"REVIEWER","approved":true,"state":"approved"},
                     {"role":"REVIEWER","approved":false,"state":"changes_requested"}]}
    """

    private func service(_ stub: StubTransport, user: HostingUser? = Self.me) -> any HostingService {
        stubService(.bitbucket, user: user, transport: stub, authorization: .basic(username: "mona@example.com", password: "token"))
    }

    @Test func readsTheUserWithBasicAuth() async throws {
        let stub = StubTransport()
        stub.on("GET", "api.bitbucket.org/2.0/user", json: """
        {"username":"mona","display_name":"Mona","account_id":"5f","uuid":"{1111-2222}",
         "links":{"avatar":{"href":"https://avatar.example/m"}}}
        """)
        let user = try await service(stub).currentUser()
        #expect(user == HostingUser(login: "mona", name: "Mona", avatarURL: URL(string: "https://avatar.example/m"), serviceID: "{1111-2222}"))
        let expected = "Basic " + Data("mona@example.com:token".utf8).base64EncodedString()
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") == expected)
    }

    @Test func listsRepositoriesWithAQueryAndNextPage() async throws {
        let stub = StubTransport()
        stub.on("GET", "/2.0/repositories?", json: """
        {"pagelen":30,"page":1,"values":[\(Self.repoJSON)],"next":"https://api.bitbucket.org/2.0/repositories?page=2"}
        """)
        let page = try await service(stub).repositories(.member, query: #"my "app""#, page: nil)
        let repository = try #require(page.items.first)
        #expect(repository.path.fullPath == "team/project")
        #expect(repository.isPrivate)
        #expect(repository.defaultBranch == "main")
        #expect(repository.httpsURL == "https://bitbucket.org/team/project.git")
        #expect(repository.sshURL == "git@bitbucket.org:team/project.git")
        #expect(repository.updatedAt != nil)
        #expect(page.next == .url(URL(string: "https://api.bitbucket.org/2.0/repositories?page=2")!))
        let request = try #require(stub.last("GET", "/repositories"))
        #expect(request.query("role") == "member")
        #expect(request.query("q") == #"name ~ "my \"app\"""#)
    }

    @Test func followsTheNextURL() async throws {
        let stub = StubTransport()
        stub.on("GET", "page=2", json: #"{"values":[]}"#)
        let page = try await service(stub)
            .repositories(.member, query: "", page: .url(URL(string: "https://api.bitbucket.org/2.0/repositories?page=2")!))
        #expect(page.items.isEmpty)
        #expect(page.next == nil)
    }

    @Test func hasNoStarredRepositories() async throws {
        await #expect(throws: HostingError.unsupported("Bitbucket has no starred repositories.")) {
            _ = try await service(StubTransport()).repositories(.starred, query: "", page: nil)
        }
    }

    @Test func ownersAreTheUserAndWorkspaces() async throws {
        let stub = StubTransport()
        stub.on("GET", "/user/permissions/workspaces", json: """
        {"values":[{"permission":"owner","workspace":{"slug":"mona","name":"Mona"}},
                   {"permission":"member","workspace":{"slug":"team","name":"The Team"}}]}
        """)
        stub.on("GET", "/2.0/user", json: #"{"username":"mona","display_name":"Mona","uuid":"{1111-2222}"}"#)
        let owners = try await service(stub).owners()
        #expect(owners.map(\.login) == ["mona", "team"])
        #expect(owners[0].isUser)
        #expect(owners[1].displayName == "The Team")
    }

    @Test func createsARepositoryUnderASlug() async throws {
        let stub = StubTransport()
        stub.on("POST", "/repositories/team/my-project", json: Self.repoJSON)
        let draft = NewRepositoryDraft(
            owner: HostingOwner(login: "team", displayName: "The Team", isUser: false), name: "My Project",
            description: "A project", isPrivate: false
        )
        _ = try await service(stub).createRepository(draft)
        let body = try #require(stub.last("POST", "/repositories/team/my-project")?.jsonBody)
        #expect(body["scm"] as? String == "git")
        #expect(body["is_private"] as? Bool == false)
        #expect(body["name"] as? String == "My Project")
    }

    @Test func listsPullRequests() async throws {
        let stub = StubTransport()
        stub.on("GET", "/pullrequests?", json: #"{"values":[\#(Self.pullRequestJSON)],"next":"https://api.bitbucket.org/2.0/x?page=2"}"#)
        let page = try await service(stub).pullRequests(in: Self.repo, filter: .closed, page: nil)
        let pr = try #require(page.items.first)
        #expect(pr.number == 7)
        #expect(pr.isDraft)
        #expect(pr.state == .open)
        #expect(pr.review == .changesRequested)
        #expect(pr.commentCount == 2)
        #expect(pr.head.name == "feature/login")
        #expect(pr.head.sha == "aaaaaaaaaaaa")
        #expect(pr.head.repository?.httpsURL == "https://bitbucket.org/mona/project.git")
        #expect(pr.head.repository?.sshURL == "git@bitbucket.org:mona/project.git")
        #expect(pr.isFromOtherRepository)
        #expect(pr.author?.login == "mona")
        #expect(pr.webURL?.absoluteString == "https://bitbucket.org/team/project/pull-requests/7")
        #expect(page.next != nil)
        #expect(stub.last("GET", "/pullrequests")?.query("state") == "DECLINED")
    }

    @Test func filtersByAuthorAndReviewer() async throws {
        let stub = StubTransport()
        stub.on("GET", "/pullrequests?", json: #"{"values":[]}"#)
        let service = service(stub)
        _ = try await service.pullRequests(in: Self.repo, filter: .mine, page: nil)
        #expect(stub.last("GET", "/pullrequests")?.query("q") == #"author.uuid = "{1111-2222}" AND state = "OPEN""#)
        _ = try await service.pullRequests(in: Self.repo, filter: .reviewRequested, page: nil)
        #expect(stub.last("GET", "/pullrequests")?.query("q") == #"reviewers.uuid = "{1111-2222}" AND state = "OPEN""#)
    }

    @Test func statesRead() throws {
        for (state, expected) in [("MERGED", PullRequestState.merged), ("DECLINED", .closed), ("SUPERSEDED", .closed)] {
            let json = #"{"id":1,"title":"T","state":"\#(state)"}"#
            let pr = try HostingClient.decoder.decode(BitbucketService.BitbucketPullRequest.self, from: Data(json.utf8))
            #expect(pr.pullRequest.state == expected)
            #expect(pr.pullRequest.review == nil)
        }
    }

    @Test func detailCarriesChecks() async throws {
        let stub = StubTransport()
        stub.on("GET", "/pullrequests/7/statuses", json: """
        {"values":[{"type":"build","state":"SUCCESSFUL","key":"a"},{"type":"build","state":"INPROGRESS","key":"b"}]}
        """)
        stub.on("GET", "/pullrequests/7", json: Self.pullRequestJSON)
        let pr = try await service(stub).pullRequest(in: Self.repo, number: 7)
        #expect(pr.checks == .pending)
        #expect(BitbucketService.summarize(["SUCCESSFUL", "FAILED"]) == .failure)
        #expect(BitbucketService.summarize(["SUCCESSFUL"]) == .success)
        #expect(BitbucketService.summarize(["STOPPED"]) == .neutral)
        #expect(BitbucketService.summarize([]) == nil)
    }

    @Test func readsCommitsFilesAndComments() async throws {
        let stub = StubTransport()
        stub.on("GET", "/pullrequests/7/commits", json: """
        {"values":[{"hash":"a1","message":"Add login\\n\\nBody","date":"2024-05-01T10:00:00+00:00",
                    "author":{"raw":"Mona <mona@example.com>"}}],
         "next":"https://api.bitbucket.org/2.0/repositories/team/project/pullrequests/7/commits?page=2"}
        """, once: true)
        stub.on("GET", "/pullrequests/7/commits?page=2", json: """
        {"values":[{"hash":"a2","message":"Fix","author":{"raw":"Octo <o@example.com>","user":{"display_name":"Octo Cat"}}}]}
        """)
        stub.on("GET", "/pullrequests/7/diffstat", json: """
        {"values":[{"status":"renamed","lines_added":1,"lines_removed":2,"old":{"path":"a.swift"},"new":{"path":"b.swift"}},
                   {"status":"removed","old":{"path":"c.swift"},"new":null},
                   {"status":"added","new":{"path":"d.swift"}}]}
        """)
        stub.on("GET", "/pullrequests/7/comments", json: """
        {"values":[{"id":3,"content":{"raw":"Later"},"user":{"nickname":"octo"},"created_on":"2024-05-03T10:00:00+00:00"},
                   {"id":2,"content":{"raw":"Nit"},"user":{"nickname":"octo"},"created_on":"2024-05-02T10:00:00+00:00",
                    "inline":{"path":"b.swift","to":4,"from":null}},
                   {"id":1,"content":{"raw":""},"deleted":true,"created_on":"2024-05-01T10:00:00+00:00"}]}
        """)
        let service = service(stub)
        let commits = try await service.commits(in: Self.repo, number: 7)
        #expect(commits.map(\.sha) == ["a1", "a2"])
        #expect(commits[0].subject == "Add login")
        #expect(commits[0].authorName == "Mona")
        #expect(commits[1].authorName == "Octo Cat")
        let files = try await service.changedFiles(in: Self.repo, number: 7)
        #expect(files.map(\.path) == ["b.swift", "c.swift", "d.swift"])
        #expect(files[0].previousPath == "a.swift")
        #expect(files.map(\.status) == [.renamed, .deleted, .added])
        let comments = try await service.conversation(in: Self.repo, number: 7)
        #expect(comments.map(\.id) == ["c2", "c3"])
        #expect(comments[0].kind == .lineComment(path: "b.swift", line: 4))
    }

    @Test func writesReviewsMergesAndDeclines() async throws {
        let stub = StubTransport()
        stub.on("POST", "/pullrequests/7/approve", json: "{}")
        stub.on("POST", "/pullrequests/7/request-changes", json: "{}")
        stub.on("POST", "/pullrequests/7/comments", status: 201, json: "{}")
        stub.on("POST", "/pullrequests/7/merge", json: Self.pullRequestJSON)
        stub.on("POST", "/pullrequests/7/decline", json: Self.pullRequestJSON)
        let service = service(stub)
        try await service.review(.approve, body: "", in: Self.repo, number: 7)
        #expect(stub.last("POST", "/approve") != nil)
        #expect(stub.last("POST", "/comments") == nil)
        try await service.review(.requestChanges, body: "Please fix", in: Self.repo, number: 7)
        #expect(stub.last("POST", "/request-changes") != nil)
        let comment = try #require(stub.last("POST", "/comments")?.jsonBody?["content"] as? [String: Any])
        #expect(comment["raw"] as? String == "Please fix")
        try await service.merge(in: Self.repo, number: 7, method: .rebase, expectedHead: nil)
        #expect(stub.last("POST", "/merge")?.jsonBody?["merge_strategy"] as? String == "fast_forward")
        try await service.merge(in: Self.repo, number: 7, method: .squash, expectedHead: nil)
        #expect(stub.last("POST", "/merge")?.jsonBody?["merge_strategy"] as? String == "squash")
        try await service.setOpen(false, in: Self.repo, number: 7)
        #expect(stub.last("POST", "/decline") != nil)
        await #expect(throws: HostingError.self) {
            try await service.setOpen(true, in: Self.repo, number: 7)
        }
    }

    @Test func createsAPullRequestFromAnotherOwner() async throws {
        let stub = StubTransport()
        stub.on("POST", "/repositories/team/project/pullrequests", status: 201, json: Self.pullRequestJSON)
        let draft = NewPullRequestDraft(base: "main", head: "feature/login", headOwner: "mona", title: "T", body: "B", isDraft: true)
        let pr = try await service(stub).createPullRequest(draft, in: Self.repo)
        #expect(pr.number == 7)
        let body = try #require(stub.last("POST", "/pullrequests")?.jsonBody)
        let source = try #require(body["source"] as? [String: Any])
        #expect((source["branch"] as? [String: Any])?["name"] as? String == "feature/login")
        #expect((source["repository"] as? [String: Any])?["full_name"] as? String == "mona/project")
        #expect(((body["destination"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String == "main")
        #expect(body["description"] as? String == "B")
        #expect(body["draft"] as? Bool == true)
    }

    @Test func errorsMap() async throws {
        let stub = StubTransport()
        stub.on("POST", "/pullrequests/7/merge", status: 400, json: """
        {"type":"error","error":{"message":"You can't merge until you resolve all merge conflicts.","detail":"Conflicts"}}
        """)
        stub.on("GET", "/pullrequests/8", status: 403, json: #"{"type":"error","error":{"message":"Missing scope"}}"#)
        let service = service(stub)
        await #expect(throws: HostingError.rejected(message: "You can't merge until you resolve all merge conflicts.. Conflicts")) {
            try await service.merge(in: Self.repo, number: 7, method: .merge, expectedHead: nil)
        }
        await #expect(throws: HostingError.forbidden(host: "bitbucket.org", message: "Missing scope")) {
            _ = try await service.pullRequest(in: Self.repo, number: 8)
        }
        #expect(service.headReference(number: 7) == nil)
        #expect(!service.capabilities.canReopen)
    }
}
