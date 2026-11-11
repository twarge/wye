import Foundation

/// GitLab, on gitlab.com or self-managed, through API v4. Projects are
/// addressed by their full path, encoded as one segment
/// (`/projects/group%2Fsub%2Fproject`); merge requests by their `iid`.
struct GitLabService: HostingService {
    var client: HostingClient
    var user: HostingUser?

    var kind: HostingKind { .gitlab }

    var capabilities: HostingCapabilities {
        // Rebasing is a project setting on GitLab, not a choice per merge,
        // and requesting changes has no simple REST call.
        HostingCapabilities(
            mergeMethods: [.merge, .squash], canApprove: true, canRequestChanges: false,
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
        let url: URL
        if case .url(let next) = page {
            url = next
        } else {
            let query = query.trimmingCharacters(in: .whitespaces)
            var items: [String: String?] = [
                "order_by": "last_activity_at", "per_page": String(Self.pageSize), "simple": "false"
            ]
            switch filter {
            case .member: items["membership"] = "true"
            case .starred: items["starred"] = "true"
            }
            if !query.isEmpty {
                items["search"] = query
                items["search_namespaces"] = "true"
            }
            url = client.url("/projects", query: items)
        }
        let response = try await client.send(.get, url, as: [Project].self)
        return Page(items: response.value.compactMap(\.hostingRepository), next: Self.next(response, after: url))
    }

    func owners() async throws -> [HostingOwner] {
        let me = try await currentUser()
        let groups = try await client.send(
            .get, client.url("/groups", query: ["min_access_level": "30", "per_page": "100"]), as: [Group].self
        ).value
        return [HostingOwner(login: me.login, displayName: me.displayName, isUser: true, serviceID: nil)]
            + groups.map { HostingOwner(login: $0.full_path, displayName: $0.full_name ?? $0.name ?? $0.full_path, isUser: false, serviceID: $0.id.value) }
    }

    func createRepository(_ draft: NewRepositoryDraft) async throws -> HostingRepository {
        var body: [String: Any] = [
            "name": draft.name, "path": draft.name, "description": draft.description,
            "visibility": draft.isPrivate ? "private" : "public"
        ]
        if !draft.owner.isUser {
            let namespace: String
            if let id = draft.owner.serviceID {
                namespace = id
            } else {
                namespace = try await client.send(
                    .get, client.url("/groups/\(Self.project(draft.owner.login))"), as: Group.self
                ).value.id.value
            }
            body["namespace_id"] = Int(namespace) ?? namespace
        }
        let project = try await client.send(.post, client.url("/projects"), json: body, as: Project.self).value
        guard let repository = project.hostingRepository else { throw HostingError.invalidResponse }
        return repository
    }

    // MARK: Merge requests

    func pullRequests(in repository: RepositoryPath, filter: PullRequestFilter, page: PageCursor?) async throws -> Page<PullRequest> {
        let url: URL
        if case .url(let next) = page {
            url = next
        } else {
            var items: [String: String?] = [
                "order_by": "updated_at", "sort": "desc", "per_page": String(Self.pageSize), "scope": "all"
            ]
            switch filter {
            case .open: items["state"] = "opened"
            case .closed: items["state"] = "closed"
            case .merged: items["state"] = "merged"
            case .mine:
                items["state"] = "opened"
                items["scope"] = "created_by_me"
            case .reviewRequested:
                items["state"] = "opened"
                guard let login = user?.login else { throw HostingError.noAccount(host: client.host) }
                items["reviewer_username"] = login
            }
            url = client.url(mergeRequestsPath(repository), query: items)
        }
        let response = try await client.send(.get, url, as: [MergeRequest].self)
        let items = response.value.map { $0.pullRequest(base: repository, head: nil) }
        return Page(items: items, next: Self.next(response, after: url))
    }

    func pullRequest(in repository: RepositoryPath, number: Int) async throws -> PullRequest {
        let path = mergeRequestsPath(repository) + "/\(number)"
        let request = try await client.send(.get, client.url(path), as: MergeRequest.self).value
        var head: Project?
        if let source = request.source_project_id, let target = request.target_project_id, source.value != target.value {
            // A contribution from another project: its addresses, to fetch from.
            head = try? await client.send(.get, client.url("/projects/\(source.value)"), as: Project.self).value
        }
        var pullRequest = request.pullRequest(base: repository, head: head)
        if let approvals = try? await client.send(.get, client.url(path + "/approvals"), as: Approvals.self).value,
           approvals.approved == true {
            pullRequest.review = .approved
        }
        return pullRequest
    }

    func commits(in repository: RepositoryPath, number: Int) async throws -> [PullRequestCommit] {
        // The API lists newest first; the conversation reads oldest first.
        try await all(client.url(mergeRequestsPath(repository) + "/\(number)/commits", query: ["per_page": "100"]), as: Commit.self)
            .map(\.pullRequestCommit).reversed()
    }

    func changedFiles(in repository: RepositoryPath, number: Int) async throws -> [PullRequestFile] {
        let base = mergeRequestsPath(repository) + "/\(number)"
        do {
            return try await all(client.url(base + "/diffs", query: ["per_page": "100"]), as: Diff.self).map(\.pullRequestFile)
        } catch HostingError.notFound {
            // GitLab before 15.7 has only `changes`.
            let changes = try await client.send(.get, client.url(base + "/changes"), as: Changes.self).value
            return (changes.changes ?? []).map(\.pullRequestFile)
        }
    }

    func conversation(in repository: RepositoryPath, number: Int) async throws -> [PullRequestComment] {
        let url = client.url(
            mergeRequestsPath(repository) + "/\(number)/notes",
            query: ["sort": "asc", "order_by": "created_at", "per_page": "100"]
        )
        return try await all(url, as: Note.self).compactMap(\.comment)
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    func addComment(_ body: String, in repository: RepositoryPath, number: Int) async throws {
        try await client.sendRaw(.post, client.url(mergeRequestsPath(repository) + "/\(number)/notes"), json: ["body": body])
    }

    func review(_ verdict: ReviewVerdict, body: String, in repository: RepositoryPath, number: Int) async throws {
        let base = mergeRequestsPath(repository) + "/\(number)"
        switch verdict {
        case .approve:
            try await client.sendRaw(.post, client.url(base + "/approve"), json: [String: Any]())
            if !body.isEmpty { try await addComment(body, in: repository, number: number) }
        case .requestChanges:
            throw HostingError.unsupported("GitLab does not let Twig request changes. Leave a comment instead.")
        case .comment:
            try await addComment(body, in: repository, number: number)
        }
    }

    func merge(in repository: RepositoryPath, number: Int, method: MergeMethod, expectedHead: String?) async throws {
        guard method != .rebase else {
            throw HostingError.unsupported("GitLab chooses how to merge in the project’s settings: merge or squash here.")
        }
        var json: [String: Any] = ["squash": method == .squash]
        if let expectedHead { json["sha"] = expectedHead }
        try await client.sendRaw(.put, client.url(mergeRequestsPath(repository) + "/\(number)/merge"), json: json)
    }

    func setOpen(_ isOpen: Bool, in repository: RepositoryPath, number: Int) async throws {
        try await client.sendRaw(
            .put, client.url(mergeRequestsPath(repository) + "/\(number)"), json: ["state_event": isOpen ? "reopen" : "close"]
        )
    }

    func createPullRequest(_ draft: NewPullRequestDraft, in repository: RepositoryPath) async throws -> PullRequest {
        let title = draft.isDraft && !Self.isDraftTitle(draft.title) ? "Draft: " + draft.title : draft.title
        var json: [String: Any] = [
            "source_branch": draft.head, "target_branch": draft.base, "title": title, "description": draft.body
        ]
        var source = repository
        var head: Project?
        if let owner = draft.headOwner, owner.lowercased() != repository.owner.lowercased() {
            // From another project: posted to it, naming the target by id.
            source = RepositoryPath(owner: owner, name: repository.name)
            let target = try await client.send(.get, client.url("/projects/\(Self.project(repository.fullPath))"), as: Project.self).value
            guard let id = target.id else { throw HostingError.invalidResponse }
            json["target_project_id"] = Int(id.value) ?? id.value
            head = try? await client.send(.get, client.url("/projects/\(Self.project(source.fullPath))"), as: Project.self).value
        }
        let created = try await client.send(.post, client.url(mergeRequestsPath(source)), json: json, as: MergeRequest.self).value
        return created.pullRequest(base: repository, head: head)
    }

    func headReference(number: Int) -> String? {
        "refs/merge-requests/\(number)/head"
    }

    // MARK: Requests

    /// A project's id in a path: its full path as one encoded segment.
    static func project(_ fullPath: String) -> String {
        GitHubService.segment(fullPath)
    }

    private func mergeRequestsPath(_ repository: RepositoryPath) -> String {
        "/projects/\(Self.project(repository.fullPath))/merge_requests"
    }

    /// The next page: the `Link` header, or `X-Next-Page` applied to the
    /// URL just read.
    static func next<Value>(_ response: HostingResponse<Value>, after url: URL) -> PageCursor? {
        if let link = response.nextLink { return .url(link) }
        guard let page = response.http.value(forHTTPHeaderField: "X-Next-Page"), !page.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "page" }
        items.append(URLQueryItem(name: "page", value: page))
        components.queryItems = items
        return components.url.map(PageCursor.url)
    }

    private func all<Item: Decodable>(_ url: URL, as type: Item.Type) async throws -> [Item] {
        var items: [Item] = []
        var next: URL? = url
        while let url = next {
            let response = try await client.send(.get, url, as: [Item].self)
            items += response.value
            if case .url(let following) = Self.next(response, after: url), following != url {
                next = following
            } else {
                next = nil
            }
        }
        return items
    }

    static func isDraftTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return ["draft:", "[draft]", "(draft)", "wip:", "[wip]"].contains { lower.hasPrefix($0) }
    }

    static func checkStatus(_ status: String) -> CheckStatus {
        switch status {
        case "success": .success
        case "failed": .failure
        case "running", "pending", "created", "waiting_for_resource", "preparing", "scheduled": .pending
        default: .neutral
        }
    }
}

// MARK: Shapes

extension GitLabService {
    struct User: Decodable {
        var id: FlexibleID?
        var username: String
        var name: String?
        var avatar_url: URL?

        var hostingUser: HostingUser {
            HostingUser(login: username, name: name, avatarURL: avatar_url, serviceID: id?.value)
        }
    }

    struct Group: Decodable {
        var id: FlexibleID
        var full_path: String
        var name: String?
        var full_name: String?
    }

    struct Project: Decodable {
        var id: FlexibleID?
        var path_with_namespace: String
        var description: String?
        var visibility: String?
        var default_branch: String?
        var http_url_to_repo: String?
        var ssh_url_to_repo: String?
        var web_url: URL?
        var last_activity_at: Date?

        var hostingRepository: HostingRepository? {
            guard let path = RepositoryPath(path_with_namespace), let http_url_to_repo else { return nil }
            return HostingRepository(
                path: path, description: description.flatMap { $0.isEmpty ? nil : $0 },
                isPrivate: visibility != "public", defaultBranch: default_branch,
                httpsURL: http_url_to_repo, sshURL: ssh_url_to_repo, webURL: web_url, updatedAt: last_activity_at
            )
        }

        var reference: RepositoryReference {
            RepositoryReference(path: RepositoryPath(path_with_namespace), httpsURL: http_url_to_repo, sshURL: ssh_url_to_repo)
        }
    }

    struct MergeRequest: Decodable {
        struct DiffRefs: Decodable {
            var base_sha: String?
            var head_sha: String?
            var start_sha: String?
        }

        struct Pipeline: Decodable {
            var status: String?
        }

        var iid: Int
        var title: String
        var description: String?
        var state: String?
        var draft: Bool?
        var work_in_progress: Bool?
        var author: User?
        var source_branch: String?
        var target_branch: String?
        var sha: String?
        var diff_refs: DiffRefs?
        var source_project_id: FlexibleID?
        var target_project_id: FlexibleID?
        var created_at: Date?
        var updated_at: Date?
        var web_url: URL?
        var user_notes_count: Int?
        var detailed_merge_status: String?
        var merge_status: String?
        var has_conflicts: Bool?
        var head_pipeline: Pipeline?
        var pipeline: Pipeline?

        /// `head` is the source project when it is another one; within one
        /// project both sides are the base.
        func pullRequest(base: RepositoryPath, head: Project?) -> PullRequest {
            let sameProject = source_project_id == nil || source_project_id?.value == target_project_id?.value
            let baseReference = RepositoryReference(path: base, httpsURL: nil, sshURL: nil)
            let headReference = head?.reference ?? (sameProject ? baseReference : nil)
            let mergeable: Bool? = if has_conflicts == true {
                false
            } else if let detailed = detailed_merge_status {
                switch detailed {
                case "mergeable": true
                case "broken_status", "conflict", "need_rebase": false
                default: nil
                }
            } else {
                switch merge_status {
                case "can_be_merged": true
                case "cannot_be_merged": false
                default: nil
                }
            }
            let pullRequestState: PullRequestState = switch state {
            case "merged": .merged
            case "closed", "locked": .closed
            default: .open
            }
            return PullRequest(
                number: iid,
                title: title,
                body: description ?? "",
                author: author?.hostingUser,
                state: pullRequestState,
                isDraft: draft ?? work_in_progress ?? GitLabService.isDraftTitle(title),
                head: PullRequestBranch(name: source_branch ?? "", sha: diff_refs?.head_sha ?? sha, repository: headReference),
                base: PullRequestBranch(name: target_branch ?? "", sha: diff_refs?.base_sha, repository: baseReference),
                createdAt: created_at,
                updatedAt: updated_at,
                webURL: web_url,
                checks: (head_pipeline ?? pipeline)?.status.map(GitLabService.checkStatus),
                review: nil,
                commentCount: user_notes_count,
                isMergeable: mergeable
            )
        }
    }

    struct Approvals: Decodable {
        var approved: Bool?
    }

    struct Commit: Decodable {
        var id: String
        var message: String?
        var title: String?
        var author_name: String?
        var authored_date: Date?

        var pullRequestCommit: PullRequestCommit {
            PullRequestCommit(sha: id, message: message ?? title ?? "", authorName: author_name, date: authored_date)
        }
    }

    struct Diff: Decodable {
        var new_path: String
        var old_path: String?
        var new_file: Bool?
        var deleted_file: Bool?
        var renamed_file: Bool?

        var pullRequestFile: PullRequestFile {
            let status: PullRequestFile.Status = if new_file == true {
                .added
            } else if deleted_file == true {
                .deleted
            } else if renamed_file == true {
                .renamed
            } else {
                .modified
            }
            return PullRequestFile(
                path: new_path, previousPath: renamed_file == true ? old_path : nil, status: status,
                additions: nil, deletions: nil
            )
        }
    }

    struct Changes: Decodable {
        var changes: [Diff]?
    }

    struct Note: Decodable {
        struct Position: Decodable {
            var new_path: String?
            var old_path: String?
            var new_line: Int?
            var old_line: Int?
        }

        var id: FlexibleID
        var body: String?
        var author: User?
        var created_at: Date?
        var system: Bool?
        var position: Position?

        /// System notes ("added 2 commits", "approved this merge request")
        /// are the service's own record, not the conversation.
        var comment: PullRequestComment? {
            guard system != true else { return nil }
            let kind: PullRequestComment.Kind = if let position, let path = position.new_path ?? position.old_path {
                .lineComment(path: path, line: position.new_line ?? position.old_line)
            } else {
                .comment
            }
            return PullRequestComment(id: "n\(id.value)", author: author?.hostingUser, body: body ?? "", createdAt: created_at, kind: kind)
        }
    }
}
