import Foundation

/// GitHub and GitHub Enterprise Server: REST for most things, GraphQL for
/// pull request lists, which then carry checks and review state without a
/// request per row.
struct GitHubService: HostingService {
    var client: HostingClient
    var user: HostingUser?

    var kind: HostingKind { .github }

    var capabilities: HostingCapabilities {
        HostingCapabilities(
            mergeMethods: [.merge, .squash, .rebase], canApprove: true, canRequestChanges: true,
            supportsDrafts: true, canReopen: true, hasHeadReference: true
        )
    }

    static let pageSize = 30

    // MARK: Account

    func currentUser() async throws -> HostingUser {
        try await client.send(.get, client.url("/user"), as: User.self).value.hostingUser
    }

    // MARK: Repositories

    func repositories(_ filter: RepositoryListFilter, query: String, page: PageCursor?) async throws -> Page<HostingRepository> {
        let query = query.trimmingCharacters(in: .whitespaces)
        if case .url(let next) = page {
            return try await repositoryPage(next, search: !query.isEmpty && filter == .member, query: query)
        }
        switch filter {
        case .member where !query.isEmpty:
            // Search reaches every repository of the account and its
            // organizations, not only the pages loaded so far.
            var qualifiers = "\(query) in:name fork:true"
            for owner in try await owners() {
                qualifiers += owner.isUser ? " user:\(owner.login)" : " org:\(owner.login)"
            }
            let url = client.url("/search/repositories", query: [
                "q": qualifiers, "sort": "updated", "per_page": String(Self.pageSize)
            ])
            return try await repositoryPage(url, search: true, query: query)
        case .member:
            let url = client.url("/user/repos", query: [
                "affiliation": "owner,collaborator,organization_member", "sort": "updated",
                "per_page": String(Self.pageSize)
            ])
            return try await repositoryPage(url, search: false, query: query)
        case .starred:
            let url = client.url("/user/starred", query: ["sort": "updated", "per_page": String(Self.pageSize)])
            return try await repositoryPage(url, search: false, query: query)
        }
    }

    private func repositoryPage(_ url: URL, search: Bool, query: String) async throws -> Page<HostingRepository> {
        let items: [Repo], response: HTTPURLResponse
        if search {
            let result = try await client.send(.get, url, as: SearchResult.self)
            (items, response) = (result.value.items, result.http)
        } else {
            let result = try await client.send(.get, url, as: [Repo].self)
            (items, response) = (result.value, result.http)
        }
        var repositories = items.compactMap(\.hostingRepository)
        if !search, !query.isEmpty {
            // Starred repositories have no search; this page is narrowed.
            repositories = repositories.filter { $0.path.fullPath.localizedCaseInsensitiveContains(query) }
        }
        return Page(items: repositories, next: HostingResponse(value: (), http: response).nextLink.map(PageCursor.url))
    }

    func owners() async throws -> [HostingOwner] {
        let me = try await currentUser()
        let organizations = try await client.send(
            .get, client.url("/user/orgs", query: ["per_page": "100"]), as: [Organization].self
        ).value
        return [HostingOwner(login: me.login, displayName: me.displayName, isUser: true)]
            + organizations.map { HostingOwner(login: $0.login, displayName: $0.login, isUser: false) }
    }

    func createRepository(_ draft: NewRepositoryDraft) async throws -> HostingRepository {
        let path = draft.owner.isUser ? "/user/repos" : "/orgs/\(Self.segment(draft.owner.login))/repos"
        let body: [String: Any] = ["name": draft.name, "description": draft.description, "private": draft.isPrivate]
        let repo = try await client.send(.post, client.url(path), json: body, as: Repo.self).value
        guard let repository = repo.hostingRepository else { throw HostingError.invalidResponse }
        return repository
    }

    // MARK: Pull requests

    func pullRequests(in repository: RepositoryPath, filter: PullRequestFilter, page: PageCursor?) async throws -> Page<PullRequest> {
        let qualifier = switch filter {
        case .open: "is:open"
        case .closed: "is:closed is:unmerged"
        case .merged: "is:merged"
        case .mine: "is:open author:@me"
        case .reviewRequested: "is:open review-requested:@me"
        }
        let search = "repo:\(repository.fullPath) is:pr \(qualifier) sort:updated-desc"
        var variables: [String: Any] = ["q": search, "first": Self.pageSize]
        if case .token(let after) = page { variables["after"] = after }
        let data = try await graphQL(Self.searchQuery, variables: variables, as: SearchData.self)
        let connection = data.search
        return Page(
            items: connection.nodes.compactMap { $0?.pullRequest },
            next: connection.pageInfo.hasNextPage ? connection.pageInfo.endCursor.map(PageCursor.token) : nil
        )
    }

    func pullRequest(in repository: RepositoryPath, number: Int) async throws -> PullRequest {
        let data = try await graphQL(Self.detailQuery, variables: [
            "owner": repository.owner, "name": repository.name, "number": number
        ], as: DetailData.self)
        guard let pullRequest = data.repository?.pullRequest?.pullRequest else { throw HostingError.notFound(host: client.host) }
        return pullRequest
    }

    func commits(in repository: RepositoryPath, number: Int) async throws -> [PullRequestCommit] {
        try await all(client.url(repoPath(repository) + "/pulls/\(number)/commits", query: ["per_page": "100"]), as: CommitItem.self)
            .map(\.pullRequestCommit)
    }

    func changedFiles(in repository: RepositoryPath, number: Int) async throws -> [PullRequestFile] {
        try await all(client.url(repoPath(repository) + "/pulls/\(number)/files", query: ["per_page": "100"]), as: FileItem.self)
            .map(\.pullRequestFile)
    }

    func conversation(in repository: RepositoryPath, number: Int) async throws -> [PullRequestComment] {
        let base = repoPath(repository)
        async let comments = all(client.url(base + "/issues/\(number)/comments", query: ["per_page": "100"]), as: IssueComment.self)
        async let reviews = all(client.url(base + "/pulls/\(number)/reviews", query: ["per_page": "100"]), as: Review.self)
        async let lineComments = all(client.url(base + "/pulls/\(number)/comments", query: ["per_page": "100"]), as: ReviewComment.self)
        let items = try await comments.map(\.comment)
            + reviews.compactMap(\.comment)
            + lineComments.map(\.comment)
        return items.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    func addComment(_ body: String, in repository: RepositoryPath, number: Int) async throws {
        try await client.sendRaw(.post, client.url(repoPath(repository) + "/issues/\(number)/comments"), json: ["body": body])
    }

    func review(_ verdict: ReviewVerdict, body: String, in repository: RepositoryPath, number: Int) async throws {
        let event = switch verdict {
        case .approve: "APPROVE"
        case .requestChanges: "REQUEST_CHANGES"
        case .comment: "COMMENT"
        }
        var json: [String: Any] = ["event": event]
        if !body.isEmpty { json["body"] = body }
        try await client.sendRaw(.post, client.url(repoPath(repository) + "/pulls/\(number)/reviews"), json: json)
    }

    func merge(in repository: RepositoryPath, number: Int, method: MergeMethod, expectedHead: String?) async throws {
        var json: [String: Any] = ["merge_method": method.rawValue]
        if let expectedHead { json["sha"] = expectedHead }
        try await client.sendRaw(.put, client.url(repoPath(repository) + "/pulls/\(number)/merge"), json: json)
    }

    func setOpen(_ isOpen: Bool, in repository: RepositoryPath, number: Int) async throws {
        try await client.sendRaw(
            .patch, client.url(repoPath(repository) + "/pulls/\(number)"), json: ["state": isOpen ? "open" : "closed"]
        )
    }

    func createPullRequest(_ draft: NewPullRequestDraft, in repository: RepositoryPath) async throws -> PullRequest {
        let json: [String: Any] = [
            "title": draft.title, "body": draft.body, "base": draft.base, "draft": draft.isDraft,
            "head": draft.headOwner.map { "\($0):\(draft.head)" } ?? draft.head
        ]
        return try await client.send(.post, client.url(repoPath(repository) + "/pulls"), json: json, as: RESTPullRequest.self)
            .value.pullRequest
    }

    func headReference(number: Int) -> String? {
        "refs/pull/\(number)/head"
    }

    // MARK: Requests

    private func repoPath(_ repository: RepositoryPath) -> String {
        "/repos/\(Self.segment(repository.owner))/\(Self.segment(repository.name))"
    }

    /// GraphQL lives at `/graphql` on github.com's API host and at
    /// `/api/graphql` on GitHub Enterprise, beside `/api/v3`.
    var graphQLURL: URL {
        let base = client.apiBase.absoluteString
        if base.hasSuffix("/api/v3") || base.hasSuffix("/api/v3/") {
            return URL(string: base.replacingOccurrences(of: "/api/v3", with: "/api/graphql").trimmingCharacters(in: CharacterSet(charactersIn: "/")))!
        }
        return client.url("/graphql")
    }

    private func graphQL<Value: Decodable>(_ query: String, variables: [String: Any], as type: Value.Type) async throws -> Value {
        let response = try await client.send(
            .post, graphQLURL, json: ["query": query, "variables": variables], as: GraphQLResponse<Value>.self
        ).value
        if let error = response.errors?.first {
            switch error.type {
            case "RATE_LIMITED": throw HostingError.rateLimited(host: client.host, reset: nil)
            case "FORBIDDEN", "INSUFFICIENT_SCOPES": throw HostingError.forbidden(host: client.host, message: error.message)
            case "NOT_FOUND": throw HostingError.notFound(host: client.host)
            default: if response.data == nil { throw HostingError.rejected(message: error.message ?? "GitHub refused the query.") }
            }
        }
        guard let data = response.data else { throw HostingError.invalidResponse }
        return data
    }

    /// Every page of a REST list, following `Link` headers. Pull requests
    /// cap commits at 250 and files at 3000, so this ends.
    private func all<Item: Decodable>(_ url: URL, as type: Item.Type) async throws -> [Item] {
        var items: [Item] = []
        var next: URL? = url
        while let url = next {
            let response = try await client.send(.get, url, as: [Item].self)
            items += response.value
            next = response.nextLink
        }
        return items
    }

    /// Percent-encodes one path segment.
    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: GraphQL documents

    static let pullRequestFields = """
    number title body isDraft state createdAt updatedAt url mergeable reviewDecision
    author { login avatarUrl }
    headRefName headRefOid baseRefName baseRefOid
    headRepository { nameWithOwner url sshUrl }
    baseRepository { nameWithOwner url sshUrl }
    comments { totalCount }
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    """

    static let searchQuery = """
    query($q: String!, $first: Int!, $after: String) {
      search(query: $q, type: ISSUE, first: $first, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { ... on PullRequest { \(pullRequestFields) } }
      }
    }
    """

    static let detailQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) { \(pullRequestFields) } }
    }
    """
}

// MARK: Shapes

extension GitHubService {
    struct User: Decodable {
        var login: String
        var name: String?
        var avatar_url: URL?
        var id: Int?

        var hostingUser: HostingUser {
            HostingUser(login: login, name: name, avatarURL: avatar_url, serviceID: id.map(String.init))
        }
    }

    struct Organization: Decodable {
        var login: String
    }

    struct Repo: Decodable {
        var full_name: String
        var description: String?
        var `private`: Bool?
        var visibility: String?
        var default_branch: String?
        var clone_url: String?
        var ssh_url: String?
        var html_url: URL?
        var updated_at: Date?
        var pushed_at: Date?

        var hostingRepository: HostingRepository? {
            guard let path = RepositoryPath(full_name), let clone_url else { return nil }
            return HostingRepository(
                path: path, description: description, isPrivate: `private` ?? (visibility != "public"),
                defaultBranch: default_branch, httpsURL: clone_url, sshURL: ssh_url, webURL: html_url,
                updatedAt: pushed_at ?? updated_at
            )
        }
    }

    struct SearchResult: Decodable {
        var items: [Repo]
    }

    struct GraphQLResponse<Value: Decodable>: Decodable {
        struct Failure: Decodable {
            var type: String?
            var message: String?
        }

        var data: Value?
        var errors: [Failure]?
    }

    struct SearchData: Decodable {
        struct Connection: Decodable {
            struct PageInfo: Decodable {
                var hasNextPage: Bool
                var endCursor: String?
            }

            var pageInfo: PageInfo
            /// Search can match issues too, which come as empty objects.
            var nodes: [GraphPullRequest?]
        }

        var search: Connection
    }

    struct DetailData: Decodable {
        struct Repository: Decodable {
            var pullRequest: GraphPullRequest?
        }

        var repository: Repository?
    }

    struct GraphPullRequest: Decodable {
        struct Author: Decodable {
            var login: String
            var avatarUrl: URL?
        }

        struct Repository: Decodable {
            var nameWithOwner: String
            var url: String?
            var sshUrl: String?

            var reference: RepositoryReference {
                RepositoryReference(path: RepositoryPath(nameWithOwner), httpsURL: url.map { $0 + ".git" }, sshURL: sshUrl)
            }
        }

        struct Count: Decodable {
            var totalCount: Int
        }

        struct Commits: Decodable {
            struct Node: Decodable {
                struct Commit: Decodable {
                    struct Rollup: Decodable {
                        var state: String
                    }

                    var statusCheckRollup: Rollup?
                }

                var commit: Commit
            }

            var nodes: [Node?]?
        }

        var number: Int?
        var title: String?
        var body: String?
        var isDraft: Bool?
        var state: String?
        var createdAt: Date?
        var updatedAt: Date?
        var url: URL?
        var mergeable: String?
        var reviewDecision: String?
        var author: Author?
        var headRefName: String?
        var headRefOid: String?
        var baseRefName: String?
        var baseRefOid: String?
        var headRepository: Repository?
        var baseRepository: Repository?
        var comments: Count?
        var commits: Commits?

        var pullRequest: PullRequest? {
            guard let number, let title else { return nil }
            let rollup = commits?.nodes?.last??.commit.statusCheckRollup?.state
            return PullRequest(
                number: number,
                title: title,
                body: body ?? "",
                author: author.map { HostingUser(login: $0.login, avatarURL: $0.avatarUrl) },
                state: pullRequestState,
                isDraft: isDraft ?? false,
                head: PullRequestBranch(name: headRefName ?? "", sha: headRefOid, repository: headRepository?.reference),
                base: PullRequestBranch(name: baseRefName ?? "", sha: baseRefOid, repository: baseRepository?.reference),
                createdAt: createdAt,
                updatedAt: updatedAt,
                webURL: url,
                checks: rollup.map(GitHubService.checkStatus),
                review: reviewState,
                commentCount: comments?.totalCount,
                isMergeable: isMergeable
            )
        }

        private var pullRequestState: PullRequestState {
            switch state {
            case "MERGED": .merged
            case "CLOSED": .closed
            default: .open
            }
        }

        private var reviewState: ReviewState? {
            switch reviewDecision {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changesRequested
            case "REVIEW_REQUIRED": .reviewRequired
            default: nil
            }
        }

        private var isMergeable: Bool? {
            switch mergeable {
            case "MERGEABLE": true
            case "CONFLICTING": false
            default: nil
            }
        }
    }

    static func checkStatus(_ state: String) -> CheckStatus {
        switch state.uppercased() {
        case "SUCCESS": .success
        case "FAILURE", "ERROR": .failure
        case "PENDING", "EXPECTED": .pending
        default: .neutral
        }
    }

    struct RESTPullRequest: Decodable {
        struct Side: Decodable {
            struct Repo: Decodable {
                var full_name: String
                var clone_url: String?
                var ssh_url: String?
            }

            var ref: String
            var sha: String?
            var repo: Repo?
        }

        var number: Int
        var title: String
        var body: String?
        var state: String
        var draft: Bool?
        var merged_at: Date?
        var merged: Bool?
        var user: User?
        var head: Side
        var base: Side
        var created_at: Date?
        var updated_at: Date?
        var html_url: URL?
        var mergeable: Bool?
        var comments: Int?

        var pullRequest: PullRequest {
            func side(_ side: Side) -> PullRequestBranch {
                PullRequestBranch(
                    name: side.ref, sha: side.sha,
                    repository: side.repo.map {
                        RepositoryReference(path: RepositoryPath($0.full_name), httpsURL: $0.clone_url, sshURL: $0.ssh_url)
                    }
                )
            }
            return PullRequest(
                number: number, title: title, body: body ?? "", author: user?.hostingUser,
                state: merged_at != nil || merged == true ? .merged : state == "closed" ? .closed : .open,
                isDraft: draft ?? false, head: side(head), base: side(base), createdAt: created_at,
                updatedAt: updated_at, webURL: html_url, commentCount: comments, isMergeable: mergeable
            )
        }
    }

    struct CommitItem: Decodable {
        struct Commit: Decodable {
            struct Person: Decodable {
                var name: String?
                var date: Date?
            }

            var message: String
            var author: Person?
        }

        var sha: String
        var commit: Commit

        var pullRequestCommit: PullRequestCommit {
            PullRequestCommit(sha: sha, message: commit.message, authorName: commit.author?.name, date: commit.author?.date)
        }
    }

    struct FileItem: Decodable {
        var filename: String
        var status: String?
        var additions: Int?
        var deletions: Int?
        var previous_filename: String?

        var pullRequestFile: PullRequestFile {
            PullRequestFile(
                path: filename, previousPath: previous_filename,
                status: fileStatus,
                additions: additions, deletions: deletions
            )
        }

        private var fileStatus: PullRequestFile.Status {
            switch status {
            case "added": .added
            case "removed": .deleted
            case "renamed": .renamed
            case "modified", "changed": .modified
            default: .other
            }
        }
    }

    struct IssueComment: Decodable {
        var id: Int
        var user: User?
        var body: String?
        var created_at: Date?

        var comment: PullRequestComment {
            PullRequestComment(id: "c\(id)", author: user?.hostingUser, body: body ?? "", createdAt: created_at, kind: .comment)
        }
    }

    struct Review: Decodable {
        var id: Int
        var user: User?
        var body: String?
        var state: String?
        var submitted_at: Date?

        /// Pending reviews are the viewer's unsent drafts; a plain comment
        /// review with no text says nothing beyond its line comments.
        var comment: PullRequestComment? {
            let verdict: ReviewVerdict? = switch state {
            case "APPROVED": .approve
            case "CHANGES_REQUESTED": .requestChanges
            case "COMMENTED": .comment
            default: nil
            }
            guard state != "PENDING", verdict != .comment || !(body ?? "").isEmpty else { return nil }
            return PullRequestComment(
                id: "r\(id)", author: user?.hostingUser, body: body ?? "", createdAt: submitted_at, kind: .review(verdict)
            )
        }
    }

    struct ReviewComment: Decodable {
        var id: Int
        var user: User?
        var body: String?
        var created_at: Date?
        var path: String
        var line: Int?
        var original_line: Int?

        var comment: PullRequestComment {
            PullRequestComment(
                id: "l\(id)", author: user?.hostingUser, body: body ?? "", createdAt: created_at,
                kind: .lineComment(path: path, line: line ?? original_line)
            )
        }
    }
}
