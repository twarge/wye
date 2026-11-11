import Foundation

/// Gitea and Forgejo (Codeberg among them), whose v1 APIs agree on
/// everything Wye uses. Versions differ in which fields they send, so
/// every field is optional where any version leaves it out.
struct GiteaService: HostingService {
    var client: HostingClient
    var user: HostingUser?

    var kind: HostingKind { .gitea }

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
        let number = Self.pageNumber(page)
        let search = filter == .member && !query.isEmpty
        let url: URL
        if case .url(let next) = page {
            url = next
        } else if search {
            url = client.url("/repos/search", query: [
                "q": query, "uid": user?.serviceID, "limit": String(Self.pageSize), "page": String(number),
                "sort": "updated", "order": "desc"
            ])
        } else {
            let path = filter == .starred ? "/user/starred" : "/user/repos"
            url = client.url(path, query: ["limit": String(Self.pageSize), "page": String(number)])
        }
        let items: [Repo], http: HTTPURLResponse
        if search {
            let response = try await client.send(.get, url, as: SearchResult.self)
            (items, http) = (response.value.data ?? [], response.http)
        } else {
            let response = try await client.send(.get, url, as: [Repo].self)
            (items, http) = (response.value, response.http)
        }
        var repositories = items.compactMap(\.hostingRepository)
        if !search, !query.isEmpty {
            // Starred repositories have no search; this page is narrowed.
            repositories = repositories.filter { $0.path.fullPath.localizedCaseInsensitiveContains(query) }
        }
        return Page(items: repositories, next: Self.next(http: http, count: items.count, page: number))
    }

    func owners() async throws -> [HostingOwner] {
        let me = try await currentUser()
        let organizations = try await client.send(
            .get, client.url("/user/orgs", query: ["limit": "50"]), as: [Organization].self
        ).value
        return [HostingOwner(login: me.login, displayName: me.displayName, isUser: true)]
            + organizations.compactMap { organization in
                guard let login = organization.username ?? organization.name else { return nil }
                let full = organization.full_name ?? ""
                return HostingOwner(login: login, displayName: full.isEmpty ? login : full, isUser: false)
            }
    }

    func createRepository(_ draft: NewRepositoryDraft) async throws -> HostingRepository {
        let path = draft.owner.isUser ? "/user/repos" : "/orgs/\(Self.segment(draft.owner.login))/repos"
        let body: [String: Any] = ["name": draft.name, "description": draft.description, "private": draft.isPrivate]
        let repo = try await client.send(.post, client.url(path), json: body, as: Repo.self).value
        guard let repository = repo.hostingRepository else { throw HostingError.invalidResponse }
        return repository
    }

    // MARK: Pull requests

    /// Gitea's list filters only by state (and, on newer versions, by
    /// author), so merged, closed, mine and review requested are narrowed
    /// here, a page at a time: a page may come back with fewer rows than
    /// the service sent, and the next page still follows.
    func pullRequests(in repository: RepositoryPath, filter: PullRequestFilter, page: PageCursor?) async throws -> Page<PullRequest> {
        let number = Self.pageNumber(page)
        let url: URL
        if case .url(let next) = page {
            url = next
        } else {
            let state = switch filter {
            case .closed, .merged: "closed"
            case .open, .mine, .reviewRequested: "open"
            }
            url = client.url(repoPath(repository) + "/pulls", query: [
                "state": state, "sort": "recentupdate", "limit": String(Self.pageSize), "page": String(number),
                "poster": filter == .mine ? user?.login : nil
            ])
        }
        let response = try await client.send(.get, url, as: [Pull].self)
        let login = user?.login.lowercased()
        let pulls = response.value.filter { pull in
            switch filter {
            case .open: true
            case .merged: pull.isMerged
            case .closed: !pull.isMerged
            case .mine: login != nil && pull.user?.login.lowercased() == login
            case .reviewRequested:
                login != nil && (pull.requested_reviewers ?? []).contains { $0.login.lowercased() == login }
            }
        }
        return Page(
            items: pulls.map(\.pullRequest),
            next: Self.next(http: response.http, count: response.value.count, page: number)
        )
    }

    func pullRequest(in repository: RepositoryPath, number: Int) async throws -> PullRequest {
        var pullRequest = try await client.send(.get, client.url(repoPath(repository) + "/pulls/\(number)"), as: Pull.self)
            .value.pullRequest
        let head = pullRequest.head.sha
        async let checks = checkStatus(in: repository, sha: head)
        async let reviews = allPages(client.url(repoPath(repository) + "/pulls/\(number)/reviews"), as: Review.self)
        pullRequest.checks = try await checks
        pullRequest.review = Self.reviewState(try await reviews)
        return pullRequest
    }

    /// The combined status of the head commit, `nil` when it has none.
    private func checkStatus(in repository: RepositoryPath, sha: String?) async throws -> CheckStatus? {
        guard let sha, !sha.isEmpty else { return nil }
        let status = try await client.send(
            .get, client.url(repoPath(repository) + "/commits/\(Self.segment(sha))/status"), as: CombinedStatus.self
        ).value
        guard (status.total_count ?? status.statuses?.count ?? 0) > 0, let state = status.state, !state.isEmpty else {
            return nil
        }
        return Self.checkStatus(state)
    }

    static func checkStatus(_ state: String) -> CheckStatus {
        switch state.lowercased() {
        case "success": .success
        case "failure", "error": .failure
        case "pending": .pending
        default: .neutral
        }
    }

    /// Each reviewer's latest approval or request for changes decides;
    /// any request for changes outweighs approvals.
    static func reviewState(_ reviews: [Review]) -> ReviewState? {
        var latest: [String: String] = [:]
        for review in reviews.sorted(by: { ($0.submitted_at ?? .distantPast) < ($1.submitted_at ?? .distantPast) }) {
            guard let state = review.state, state == "APPROVED" || state == "REQUEST_CHANGES",
                  review.dismissed != true, review.stale != true else { continue }
            latest[review.user?.login ?? "\(review.id)"] = state
        }
        if latest.values.contains("REQUEST_CHANGES") { return .changesRequested }
        if latest.values.contains("APPROVED") { return .approved }
        return nil
    }

    func commits(in repository: RepositoryPath, number: Int) async throws -> [PullRequestCommit] {
        try await allPages(client.url(repoPath(repository) + "/pulls/\(number)/commits"), as: CommitItem.self)
            .map(\.pullRequestCommit)
    }

    func changedFiles(in repository: RepositoryPath, number: Int) async throws -> [PullRequestFile] {
        try await allPages(client.url(repoPath(repository) + "/pulls/\(number)/files"), as: FileItem.self)
            .map(\.pullRequestFile)
    }

    /// Comments and reviews. Comments on lines of the diff are left out:
    /// Gitea lists them per review, a request each.
    func conversation(in repository: RepositoryPath, number: Int) async throws -> [PullRequestComment] {
        let base = repoPath(repository)
        async let comments = allPages(client.url(base + "/issues/\(number)/comments"), as: IssueComment.self)
        async let reviews = allPages(client.url(base + "/pulls/\(number)/reviews"), as: Review.self)
        let items = try await comments.map(\.comment) + reviews.compactMap(\.comment)
        return items.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    func addComment(_ body: String, in repository: RepositoryPath, number: Int) async throws {
        try await client.sendRaw(.post, client.url(repoPath(repository) + "/issues/\(number)/comments"), json: ["body": body])
    }

    func review(_ verdict: ReviewVerdict, body: String, in repository: RepositoryPath, number: Int) async throws {
        let event = switch verdict {
        case .approve: "APPROVED"
        case .requestChanges: "REQUEST_CHANGES"
        case .comment: "COMMENT"
        }
        try await client.sendRaw(
            .post, client.url(repoPath(repository) + "/pulls/\(number)/reviews"), json: ["event": event, "body": body]
        )
    }

    func merge(in repository: RepositoryPath, number: Int, method: MergeMethod, expectedHead: String?) async throws {
        var json: [String: Any] = ["Do": method.rawValue]
        if let expectedHead { json["head_commit_id"] = expectedHead }
        try await client.sendRaw(.post, client.url(repoPath(repository) + "/pulls/\(number)/merge"), json: json)
    }

    func setOpen(_ isOpen: Bool, in repository: RepositoryPath, number: Int) async throws {
        try await client.sendRaw(
            .patch, client.url(repoPath(repository) + "/pulls/\(number)"), json: ["state": isOpen ? "open" : "closed"]
        )
    }

    /// A draft is marked the way Gitea knows one: by a `WIP:` title.
    func createPullRequest(_ draft: NewPullRequestDraft, in repository: RepositoryPath) async throws -> PullRequest {
        let title = draft.isDraft && !Self.hasDraftPrefix(draft.title) ? "WIP: " + draft.title : draft.title
        let json: [String: Any] = [
            "title": title, "body": draft.body, "base": draft.base,
            "head": draft.headOwner.map { "\($0):\(draft.head)" } ?? draft.head
        ]
        return try await client.send(.post, client.url(repoPath(repository) + "/pulls"), json: json, as: Pull.self)
            .value.pullRequest
    }

    func headReference(number: Int) -> String? {
        "refs/pull/\(number)/head"
    }

    // MARK: Requests

    private func repoPath(_ repository: RepositoryPath) -> String {
        "/repos/\(Self.segment(repository.owner))/\(Self.segment(repository.name))"
    }

    private static func pageNumber(_ page: PageCursor?) -> Int {
        if case .number(let number) = page { return number }
        return 1
    }

    /// The `Link` header's next page, or, from a version that sends none,
    /// the next page number when this one came back full.
    static func next(http: HTTPURLResponse, count: Int, page: Int) -> PageCursor? {
        if let link = HostingResponse(value: (), http: http).nextLink { return .url(link) }
        if http.value(forHTTPHeaderField: "Link") != nil { return nil }
        return count >= pageSize ? .number(page + 1) : nil
    }

    /// Every page of a list, following `Link` headers, or page numbers
    /// while pages come back full.
    private func allPages<Item: Decodable>(_ url: URL, as type: Item.Type) async throws -> [Item] {
        let limit = 50
        var items: [Item] = []
        var page = 1
        var next: URL? = Self.adding(["limit": String(limit), "page": "1"], to: url)
        while let url = next, page <= 100 {
            let response = try await client.send(.get, url, as: [Item].self)
            items += response.value
            if let link = response.nextLink {
                next = link
            } else if response.http.value(forHTTPHeaderField: "Link") == nil, response.value.count >= limit {
                page += 1
                next = Self.adding(["limit": String(limit), "page": String(page)], to: url)
            } else {
                next = nil
            }
        }
        return items
    }

    private static func adding(_ values: [String: String], to url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = (components.queryItems ?? []).filter { values[$0.name] == nil }
        items += values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        return components.url!
    }

    static func segment(_ value: String) -> String {
        GitHubService.segment(value)
    }

    static func hasDraftPrefix(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return ["wip:", "[wip]", "draft:", "[draft]"].contains { lowered.hasPrefix($0) }
    }
}

// MARK: Shapes

extension GiteaService {
    struct User: Decodable {
        var login: String
        var full_name: String?
        var avatar_url: URL?
        var id: Int?

        var hostingUser: HostingUser {
            HostingUser(login: login, name: full_name, avatarURL: avatar_url, serviceID: id.map(String.init))
        }
    }

    struct Organization: Decodable {
        var username: String?
        var name: String?
        var full_name: String?
    }

    struct Repo: Decodable {
        var full_name: String
        var description: String?
        var `private`: Bool?
        var default_branch: String?
        var clone_url: String?
        var ssh_url: String?
        var html_url: URL?
        var updated_at: Date?

        var hostingRepository: HostingRepository? {
            guard let path = RepositoryPath(full_name), let clone_url else { return nil }
            return HostingRepository(
                path: path, description: description?.isEmpty == true ? nil : description,
                isPrivate: `private` ?? false, defaultBranch: default_branch, httpsURL: clone_url,
                sshURL: ssh_url, webURL: html_url, updatedAt: updated_at
            )
        }
    }

    struct SearchResult: Decodable {
        var ok: Bool?
        var data: [Repo]?
    }

    struct Pull: Decodable {
        struct Side: Decodable {
            struct Repo: Decodable {
                var full_name: String?
                var clone_url: String?
                var ssh_url: String?
            }

            var ref: String?
            var label: String?
            var sha: String?
            var repo: Repo?
        }

        var number: Int
        var title: String
        var body: String?
        var state: String?
        var merged: Bool?
        var merged_at: Date?
        var draft: Bool?
        var user: User?
        var head: Side?
        var base: Side?
        var created_at: Date?
        var updated_at: Date?
        var html_url: URL?
        var comments: Int?
        var mergeable: Bool?
        var requested_reviewers: [User]?

        var isMerged: Bool { merged == true || merged_at != nil }

        var pullRequest: PullRequest {
            func side(_ side: Side?) -> PullRequestBranch {
                PullRequestBranch(
                    name: side?.ref ?? side?.label ?? "", sha: side?.sha,
                    repository: side?.repo.map {
                        RepositoryReference(path: $0.full_name.flatMap(RepositoryPath.init), httpsURL: $0.clone_url, sshURL: $0.ssh_url)
                    }
                )
            }
            return PullRequest(
                number: number, title: title, body: body ?? "", author: user?.hostingUser,
                state: isMerged ? .merged : state == "closed" ? .closed : .open,
                isDraft: draft ?? GiteaService.hasDraftPrefix(title),
                head: side(head), base: side(base), createdAt: created_at, updatedAt: updated_at,
                webURL: html_url, commentCount: comments,
                // Gitea says `mergeable: false` for merged ones too.
                isMergeable: isMerged ? nil : mergeable
            )
        }
    }

    struct CombinedStatus: Decodable {
        struct Status: Decodable {
            var status: String?
        }

        var state: String?
        var total_count: Int?
        var statuses: [Status]?
    }

    struct Review: Decodable {
        var id: Int
        var user: User?
        var body: String?
        var state: String?
        var submitted_at: Date?
        var dismissed: Bool?
        var stale: Bool?

        /// Pending reviews are unsent drafts; a comment review with no
        /// text says nothing on its own.
        var comment: PullRequestComment? {
            let verdict: ReviewVerdict? = switch state {
            case "APPROVED": .approve
            case "REQUEST_CHANGES": .requestChanges
            case "COMMENT": .comment
            default: nil
            }
            guard state != "PENDING", state != "REQUEST_REVIEW",
                  verdict != .comment || !(body ?? "").isEmpty else { return nil }
            return PullRequestComment(
                id: "r\(id)", author: user?.hostingUser, body: body ?? "", createdAt: submitted_at, kind: .review(verdict)
            )
        }
    }

    struct CommitItem: Decodable {
        struct Commit: Decodable {
            struct Person: Decodable {
                var name: String?
                var date: Date?
            }

            var message: String?
            var author: Person?
        }

        var sha: String
        var commit: Commit?
        var created: Date?

        var pullRequestCommit: PullRequestCommit {
            PullRequestCommit(
                sha: sha, message: commit?.message ?? "", authorName: commit?.author?.name,
                date: commit?.author?.date ?? created
            )
        }
    }

    struct FileItem: Decodable {
        var filename: String
        var status: String?
        var additions: Int?
        var deletions: Int?
        var previous_filename: String?

        var pullRequestFile: PullRequestFile {
            let change: PullRequestFile.Status = switch status {
            case "added": .added
            case "deleted", "removed": .deleted
            case "renamed": .renamed
            case "modified", "changed": .modified
            default: .other
            }
            return PullRequestFile(
                path: filename, previousPath: previous_filename?.isEmpty == true ? nil : previous_filename,
                status: change, additions: additions, deletions: deletions
            )
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
}
