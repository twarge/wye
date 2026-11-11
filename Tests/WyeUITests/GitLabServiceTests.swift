import Foundation
import Testing
@testable import WyeUI

/// GitLab's API v4 shapes, written from its documentation.
@Suite struct GitLabServiceTests {
    static let repo = RepositoryPath(owner: "group/sub", name: "project")
    static let encoded = "/projects/group%2Fsub%2Fproject"

    static let projectJSON = """
    {"id":42,"name":"project","path":"project","path_with_namespace":"group/sub/project","description":"A project",
     "visibility":"private","default_branch":"main","http_url_to_repo":"https://gitlab.com/group/sub/project.git",
     "ssh_url_to_repo":"git@gitlab.com:group/sub/project.git","web_url":"https://gitlab.com/group/sub/project",
     "last_activity_at":"2024-05-01T10:00:00.123Z"}
    """

    static let mergeRequestJSON = """
    {"id":900,"iid":7,"project_id":42,"title":"Draft: Add login","description":"It **works**.","state":"opened",
     "created_at":"2024-05-01T10:00:00.000Z","updated_at":"2024-05-03T10:00:00.000Z",
     "target_branch":"main","source_branch":"feature/login","user_notes_count":2,
     "author":{"id":3,"username":"mona","name":"Mona","avatar_url":"https://gitlab.com/uploads/mona.png"},
     "source_project_id":42,"target_project_id":42,"draft":true,"work_in_progress":true,
     "merge_status":"can_be_merged","detailed_merge_status":"mergeable","sha":"aaaa",
     "diff_refs":{"base_sha":"bbbb","head_sha":"aaaa","start_sha":"cccc"},
     "web_url":"https://gitlab.com/group/sub/project/-/merge_requests/7"}
    """

    @Test func readsTheUser() async throws {
        let stub = StubTransport()
        stub.on("GET", "gitlab.com/api/v4/user", json: #"{"id":3,"username":"mona","name":"Mona","avatar_url":"https://a.example/m"}"#)
        let user = try await stubService(.gitlab, transport: stub).currentUser()
        #expect(user == HostingUser(login: "mona", name: "Mona", avatarURL: URL(string: "https://a.example/m"), serviceID: "3"))
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func selfManagedUsesItsHost() async throws {
        let stub = StubTransport()
        stub.on("GET", "https://git.example.com/api/v4/user", json: #"{"username":"mona"}"#)
        let user = try await stubService(.gitlab, host: "git.example.com", transport: stub).currentUser()
        #expect(user.login == "mona")
    }

    @Test func listsProjectsWithSearchAndPages() async throws {
        let stub = StubTransport()
        stub.on("GET", "/projects?", json: "[\(Self.projectJSON)]", headers: [
            "Link": #"<https://gitlab.com/api/v4/projects?membership=true&page=2>; rel="next""#
        ])
        let page = try await stubService(.gitlab, transport: stub).repositories(.member, query: "proj", page: nil)
        let repository = try #require(page.items.first)
        #expect(repository.path == Self.repo)
        #expect(repository.isPrivate)
        #expect(repository.defaultBranch == "main")
        #expect(repository.cloneURL(preferSSH: true) == "git@gitlab.com:group/sub/project.git")
        #expect(repository.updatedAt != nil)
        #expect(page.next == .url(URL(string: "https://gitlab.com/api/v4/projects?membership=true&page=2")!))
        let request = try #require(stub.last("GET", "/projects?"))
        #expect(request.query("membership") == "true")
        #expect(request.query("search") == "proj")
        #expect(request.query("search_namespaces") == "true")
        #expect(request.query("order_by") == "last_activity_at")
    }

    @Test func followsXNextPage() async throws {
        let stub = StubTransport()
        stub.on("GET", "/projects?", json: "[\(Self.projectJSON)]", headers: ["X-Next-Page": "3"])
        let page = try await stubService(.gitlab, transport: stub).repositories(.starred, query: "", page: nil)
        guard case .url(let next) = page.next else { Issue.record("No next page"); return }
        let components = try #require(URLComponents(url: next, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "page" }?.value == "3")
        #expect(components.queryItems?.first { $0.name == "starred" }?.value == "true")

        let last = StubTransport()
        last.on("GET", "/projects?", json: "[]", headers: ["X-Next-Page": ""])
        #expect(try await stubService(.gitlab, transport: last).repositories(.member, query: "", page: nil).next == nil)
    }

    @Test func ownersIncludeGroupsWithIDs() async throws {
        let stub = StubTransport()
        stub.on("GET", "/groups", json: #"[{"id":5,"name":"Sub","full_name":"Group / Sub","full_path":"group/sub"}]"#)
        stub.on("GET", "api/v4/user", json: #"{"username":"mona","name":"Mona"}"#)
        let owners = try await stubService(.gitlab, transport: stub).owners()
        #expect(owners.map(\.login) == ["mona", "group/sub"])
        #expect(owners[1].serviceID == "5")
        #expect(owners[0].isUser)
        #expect(stub.last("GET", "/groups")?.query("min_access_level") == "30")
    }

    @Test func createsInAGroup() async throws {
        let stub = StubTransport()
        stub.on("POST", "/projects", status: 201, json: Self.projectJSON)
        let draft = NewRepositoryDraft(
            owner: HostingOwner(login: "group/sub", displayName: "Sub", isUser: false, serviceID: "5"),
            name: "project", description: "A project", isPrivate: false
        )
        let created = try await stubService(.gitlab, transport: stub).createRepository(draft)
        #expect(created.httpsURL == "https://gitlab.com/group/sub/project.git")
        let body = try #require(stub.last("POST", "/projects")?.jsonBody)
        #expect(body["namespace_id"] as? Int == 5)
        #expect(body["visibility"] as? String == "public")
        #expect(body["path"] as? String == "project")
    }

    @Test func listsMergeRequestsByFilter() async throws {
        let stub = StubTransport()
        stub.on("GET", Self.encoded + "/merge_requests?", json: "[\(Self.mergeRequestJSON)]")
        let service = stubService(.gitlab, user: HostingUser(login: "mona"), transport: stub)
        let page = try await service.pullRequests(in: Self.repo, filter: .reviewRequested, page: nil)
        let request = try #require(stub.last("GET", "/merge_requests?"))
        #expect(request.url!.absoluteString.contains(Self.encoded))
        #expect(request.query("reviewer_username") == "mona")
        #expect(request.query("state") == "opened")
        #expect(request.query("order_by") == "updated_at")
        let mr = try #require(page.items.first)
        #expect(mr.number == 7)
        #expect(mr.isDraft)
        #expect(mr.state == .open)
        #expect(mr.head.name == "feature/login")
        #expect(mr.head.sha == "aaaa")
        #expect(mr.base.sha == "bbbb")
        #expect(mr.head.repository?.path == Self.repo)
        #expect(!mr.isFromOtherRepository)
        #expect(mr.isMergeable == true)
        #expect(mr.commentCount == 2)
        #expect(mr.author?.login == "mona")

        _ = try await service.pullRequests(in: Self.repo, filter: .mine, page: nil)
        #expect(stub.last("GET", "/merge_requests?")?.query("scope") == "created_by_me")
        _ = try await service.pullRequests(in: Self.repo, filter: .merged, page: nil)
        #expect(stub.last("GET", "/merge_requests?")?.query("state") == "merged")
    }

    @Test func detailAddsPipelineApprovalsAndSourceProject() async throws {
        let stub = StubTransport()
        let other = Self.mergeRequestJSON
            .replacingOccurrences(of: #""source_project_id":42"#, with: #""source_project_id":99"#)
            .replacingOccurrences(of: #""web_url":"https://gitlab.com/group/sub/project/-/merge_requests/7"}"#,
                                  with: #""web_url":"https://gitlab.com/group/sub/project/-/merge_requests/7","head_pipeline":{"id":1,"status":"running"}}"#)
        stub.on("GET", Self.encoded + "/merge_requests/7/approvals", json: #"{"approved":true,"approvals_left":0}"#)
        stub.on("GET", Self.encoded + "/merge_requests/7", json: other)
        stub.on("GET", "/projects/99", json: """
        {"id":99,"path_with_namespace":"mona/project","http_url_to_repo":"https://gitlab.com/mona/project.git",
         "ssh_url_to_repo":"git@gitlab.com:mona/project.git"}
        """)
        let mr = try await stubService(.gitlab, transport: stub).pullRequest(in: Self.repo, number: 7)
        #expect(mr.checks == .pending)
        #expect(mr.review == .approved)
        #expect(mr.isFromOtherRepository)
        #expect(mr.head.repository?.httpsURL == "https://gitlab.com/mona/project.git")
    }

    @Test func pipelineStatuses() {
        #expect(GitLabService.checkStatus("success") == .success)
        #expect(GitLabService.checkStatus("failed") == .failure)
        #expect(GitLabService.checkStatus("running") == .pending)
        #expect(GitLabService.checkStatus("created") == .pending)
        #expect(GitLabService.checkStatus("canceled") == .neutral)
        #expect(GitLabService.checkStatus("skipped") == .neutral)
        #expect(GitLabService.checkStatus("manual") == .neutral)
    }

    @Test func readsCommitsOldestFirst() async throws {
        let stub = StubTransport()
        stub.on("GET", "/merge_requests/7/commits", json: """
        [{"id":"a2","short_id":"a2","title":"Fix","message":"Fix\\n","author_name":"Mona","authored_date":"2024-05-02T10:00:00.000+02:00"},
         {"id":"a1","title":"Add login","message":"Add login\\n\\nBody","author_name":"Mona","authored_date":"2024-05-01T10:00:00.000+02:00"}]
        """)
        let commits = try await stubService(.gitlab, transport: stub).commits(in: Self.repo, number: 7)
        #expect(commits.map(\.sha) == ["a1", "a2"])
        #expect(commits[0].subject == "Add login")
        #expect(commits[0].date != nil)
    }

    @Test func readsDiffsAcrossPages() async throws {
        let stub = StubTransport()
        stub.on("GET", "/merge_requests/7/diffs?per_page=100", json: """
        [{"old_path":"a.swift","new_path":"b.swift","a_mode":"100644","b_mode":"100644","diff":"","new_file":false,"renamed_file":true,"deleted_file":false}]
        """, headers: ["X-Next-Page": "2"], once: true)
        stub.on("GET", "/merge_requests/7/diffs", json: """
        [{"old_path":"c.swift","new_path":"c.swift","new_file":false,"renamed_file":false,"deleted_file":true},
         {"old_path":"d.swift","new_path":"d.swift","new_file":true,"renamed_file":false,"deleted_file":false}]
        """, headers: ["X-Next-Page": ""])
        let files = try await stubService(.gitlab, transport: stub).changedFiles(in: Self.repo, number: 7)
        #expect(files.map(\.path) == ["b.swift", "c.swift", "d.swift"])
        #expect(files.map(\.status) == [.renamed, .deleted, .added])
        #expect(files[0].previousPath == "a.swift")
    }

    @Test func olderGitLabFallsBackToChanges() async throws {
        let stub = StubTransport()
        stub.on("GET", "/merge_requests/7/changes", json: """
        {"iid":7,"changes":[{"old_path":"a.swift","new_path":"a.swift","new_file":false,"renamed_file":false,"deleted_file":false}]}
        """)
        let files = try await stubService(.gitlab, transport: stub).changedFiles(in: Self.repo, number: 7)
        #expect(files.map(\.status) == [.modified])
    }

    @Test func conversationSkipsSystemNotes() async throws {
        let stub = StubTransport()
        stub.on("GET", "/merge_requests/7/notes", json: """
        [{"id":1,"body":"added 1 commit","author":{"username":"mona"},"created_at":"2024-05-01T10:00:00.000Z","system":true},
         {"id":2,"body":"Looks good","author":{"username":"octo"},"created_at":"2024-05-02T10:00:00.000Z","system":false},
         {"id":3,"type":"DiffNote","body":"Nit","author":{"username":"octo"},"created_at":"2024-05-03T10:00:00.000Z","system":false,
          "position":{"base_sha":"b","start_sha":"c","head_sha":"a","old_path":"a.swift","new_path":"a.swift","position_type":"text","old_line":null,"new_line":4}}]
        """)
        let items = try await stubService(.gitlab, transport: stub).conversation(in: Self.repo, number: 7)
        #expect(items.map(\.id) == ["n2", "n3"])
        #expect(items[1].kind == .lineComment(path: "a.swift", line: 4))
        let request = try #require(stub.last("GET", "/notes"))
        #expect(request.query("sort") == "asc")
    }

    @Test func writesNotesApprovalsMergesAndState() async throws {
        let stub = StubTransport()
        stub.on("POST", "/merge_requests/7/notes", status: 201, json: "{}")
        stub.on("POST", "/merge_requests/7/approve", status: 201, json: "{}")
        stub.on("PUT", "/merge_requests/7/merge", json: "{}")
        stub.on("PUT", "/merge_requests/7", json: "{}")
        let service = stubService(.gitlab, transport: stub)
        try await service.addComment("Thanks", in: Self.repo, number: 7)
        #expect(stub.last("POST", "/notes")?.jsonBody?["body"] as? String == "Thanks")
        try await service.review(.approve, body: "", in: Self.repo, number: 7)
        #expect(stub.last("POST", "/approve") != nil)
        await #expect(throws: HostingError.self) {
            try await service.review(.requestChanges, body: "No", in: Self.repo, number: 7)
        }
        try await service.merge(in: Self.repo, number: 7, method: .squash, expectedHead: "aaaa")
        let merge = try #require(stub.last("PUT", "/merge")?.jsonBody)
        #expect(merge["squash"] as? Bool == true)
        #expect(merge["sha"] as? String == "aaaa")
        try await service.setOpen(false, in: Self.repo, number: 7)
        #expect(stub.last("PUT", "/merge_requests/7")?.jsonBody?["state_event"] as? String == "close")
        try await service.setOpen(true, in: Self.repo, number: 7)
        #expect(stub.last("PUT", "/merge_requests/7")?.jsonBody?["state_event"] as? String == "reopen")
        #expect(service.headReference(number: 7) == "refs/merge-requests/7/head")
        #expect(!service.capabilities.mergeMethods.contains(.rebase))
    }

    @Test func createsADraftMergeRequest() async throws {
        let stub = StubTransport()
        stub.on("POST", Self.encoded + "/merge_requests", status: 201, json: Self.mergeRequestJSON)
        let draft = NewPullRequestDraft(base: "main", head: "feature/login", headOwner: nil, title: "Add login", body: "Body", isDraft: true)
        let mr = try await stubService(.gitlab, transport: stub).createPullRequest(draft, in: Self.repo)
        #expect(mr.number == 7)
        let body = try #require(stub.last("POST", "/merge_requests")?.jsonBody)
        #expect(body["title"] as? String == "Draft: Add login")
        #expect(body["source_branch"] as? String == "feature/login")
        #expect(body["target_branch"] as? String == "main")
        #expect(body["description"] as? String == "Body")
        #expect(body["target_project_id"] == nil)
    }

    @Test func createsFromAnotherProject() async throws {
        let stub = StubTransport()
        stub.on("POST", "/projects/mona%2Fproject/merge_requests", status: 201, json: Self.mergeRequestJSON
            .replacingOccurrences(of: #""source_project_id":42"#, with: #""source_project_id":99"#))
        stub.on("GET", "/projects/mona%2Fproject", json: """
        {"id":99,"path_with_namespace":"mona/project","http_url_to_repo":"https://gitlab.com/mona/project.git"}
        """)
        stub.on("GET", Self.encoded, json: Self.projectJSON)
        let draft = NewPullRequestDraft(base: "main", head: "topic", headOwner: "mona", title: "T", body: "", isDraft: false)
        let mr = try await stubService(.gitlab, transport: stub).createPullRequest(draft, in: Self.repo)
        let body = try #require(stub.last("POST", "/merge_requests")?.jsonBody)
        #expect(body["target_project_id"] as? Int == 42)
        #expect(body["title"] as? String == "T")
        #expect(mr.isFromOtherRepository)
    }

    @Test func validationMessagesAreRead() async throws {
        let stub = StubTransport()
        stub.on("POST", Self.encoded + "/merge_requests", status: 409, json: """
        {"message":["Another open merge request already exists for this source branch: !7"]}
        """)
        stub.on("POST", "/projects", status: 400, json: #"{"message":{"name":["has already been taken"],"path":["has already been taken"]}}"#)
        let service = stubService(.gitlab, transport: stub)
        let draft = NewPullRequestDraft(base: "main", head: "topic", headOwner: nil, title: "T", body: "", isDraft: false)
        await #expect(throws: HostingError.rejected(message: "Another open merge request already exists for this source branch: !7")) {
            _ = try await service.createPullRequest(draft, in: Self.repo)
        }
        let repository = NewRepositoryDraft(
            owner: HostingOwner(login: "mona", displayName: "Mona", isUser: true), name: "project", description: "", isPrivate: true
        )
        await #expect(throws: HostingError.rejected(message: "name has already been taken, path has already been taken")) {
            _ = try await service.createRepository(repository)
        }
    }

    @Test func unauthorizedAndForbiddenMap() async throws {
        let stub = StubTransport()
        stub.on("GET", "api/v4/user", status: 401, json: #"{"message":"401 Unauthorized"}"#)
        stub.on("GET", "/merge_requests", status: 403, json: #"{"error":"insufficient_scope","error_description":"The request requires higher privileges than provided by the access token.","scope":"api"}"#)
        let service = stubService(.gitlab, transport: stub)
        await #expect(throws: HostingError.unauthorized(host: "gitlab.com")) {
            _ = try await service.currentUser()
        }
        await #expect(throws: HostingError.forbidden(
            host: "gitlab.com", message: "The request requires higher privileges than provided by the access token."
        )) {
            _ = try await service.pullRequests(in: Self.repo, filter: .open, page: nil)
        }
    }
}
