import Foundation

/// Bitbucket Cloud's API 2.0. Lists come as `{values, next}` pages whose
/// `next` is a full URL; queries use its filter language in `q`.
struct BitbucketService: HostingService {
    var client: HostingClient
    var user: HostingUser?

    var kind: HostingKind { .bitbucket }

    var capabilities: HostingCapabilities {
        // Bitbucket's `fast_forward` strategy stands in for rebase: it
        // fast-forwards when the branch is already on top of the base and
        // refuses otherwise. A declined pull request cannot be reopened.
        HostingCapabilities(
            mergeMethods: [.merge, .squash, .rebase], canApprove: true, canRequestChanges: true,
            supportsDrafts: true, canReopen: false, hasHeadReference: false
        )
    }

    static let pageSize = 30

    // MARK: Account

    func currentUser() async throws -> HostingUser {
        try await client.send(.get, client.url("/user"), as: Account.self).value.hostingUser
    }

    // MARK: Repositories

    func repositories(_ filter: RepositoryListFilter, query: String, page: PageCursor?) async throws -> Page<HostingRepository> {
        guard filter == .member else {
            throw HostingError.unsupported("Bitbucket has no starred repositories.")
        }
        let url: URL
        if case .url(let next) = page {
            url = next
        } else {
            let query = query.trimmingCharacters(in: .whitespaces)
            url = client.url("/repositories", query: [
                "role": "member", "sort": "-updated_on", "pagelen": String(Self.pageSize),
                "q": query.isEmpty ? nil : "name ~ \(Self.quoted(query))"
            ])
        }
        let response = try await client.send(.get, url, as: Paged<Repo>.self).value
        return Page(items: response.values.compactMap(\.hostingRepository), next: response.nextCursor)
    }

    func owners() async throws -> [HostingOwner] {
        let me = try await currentUser()
        let workspaces: [Workspace]
        do {
            workspaces = try await all(
                client.url("/user/permissions/workspaces", query: ["pagelen": "100"]), as: WorkspacePermission.self
            ).compactMap(\.workspace)
        } catch HostingError.notFound, HostingError.server(status: 410, _) {
            workspaces = try await all(client.url("/workspaces", query: ["pagelen": "100"]), as: Workspace.self)
        }
        // A personal workspace has the account's own name; it is the user.
        var owners = [HostingOwner(login: me.login, displayName: me.displayName, isUser: true)]
        for workspace in workspaces where workspace.slug.lowercased() != me.login.lowercased() {
            owners.append(HostingOwner(login: workspace.slug, displayName: workspace.name ?? workspace.slug, isUser: false))
        }
        return owners
    }

    func createRepository(_ draft: NewRepositoryDraft) async throws -> HostingRepository {
        let slug = Self.slug(for: draft.name)
        let body: [String: Any] = [
            "scm": "git", "is_private": draft.isPrivate, "description": draft.description, "name": draft.name
        ]
        let repo = try await client.send(
            .post, client.url("/repositories/\(Self.segment(draft.owner.login))/\(Self.segment(slug))"),
            json: body, as: Repo.self
        ).value
        guard let repository = repo.hostingRepository else { throw HostingError.invalidResponse }
        return repository
    }

    // MARK: Pull requests

    func pullRequests(in repository: RepositoryPath, filter: PullRequestFilter, page: PageCursor?) async throws -> Page<PullRequest> {
        let url: URL
        if case .url(let next) = page {
            url = next
        } else {
            var query: [String: String?] = ["pagelen": String(Self.pageSize), "sort": "-updated_on"]
            switch filter {
            case .open: query["state"] = "OPEN"
            case .closed: query["state"] = "DECLINED"
            case .merged: query["state"] = "MERGED"
            case .mine, .reviewRequested:
                guard let uuid = user?.serviceID else {
                    throw HostingError.unsupported("Wye does not know this Bitbucket account’s id. Sign in again in Settings.")
                }
                let field = filter == .mine ? "author.uuid" : "reviewers.uuid"
                query["state"] = "OPEN"
                query["q"] = "\(field) = \(Self.quoted(uuid)) AND state = \"OPEN\""
            }
            url = client.url(pullRequestsPath(repository), query: query)
        }
        let response = try await client.send(.get, url, as: Paged<BitbucketPullRequest>.self).value
        return Page(items: response.values.map(\.pullRequest), next: response.nextCursor)
    }

    func pullRequest(in repository: RepositoryPath, number: Int) async throws -> PullRequest {
        let base = pullRequestsPath(repository) + "/\(number)"
        var pullRequest = try await client.send(.get, client.url(base), as: BitbucketPullRequest.self).value.pullRequest
        // Statuses are a list of their own; without them the rest still shows.
        if let statuses = try? await all(client.url(base + "/statuses", query: ["pagelen": "100"]), as: Status.self) {
            pullRequest.checks = Self.summarize(statuses.map(\.state))
        }
        return pullRequest
    }

    func commits(in repository: RepositoryPath, number: Int) async throws -> [PullRequestCommit] {
        try await all(client.url(pullRequestsPath(repository) + "/\(number)/commits"), as: CommitItem.self)
            .map(\.pullRequestCommit)
    }

    func changedFiles(in repository: RepositoryPath, number: Int) async throws -> [PullRequestFile] {
        try await all(client.url(pullRequestsPath(repository) + "/\(number)/diffstat"), as: DiffStat.self)
            .compactMap(\.pullRequestFile)
    }

    func conversation(in repository: RepositoryPath, number: Int) async throws -> [PullRequestComment] {
        let comments = try await all(
            client.url(pullRequestsPath(repository) + "/\(number)/comments", query: ["pagelen": "100"]), as: Comment.self
        )
        return comments.compactMap(\.comment)
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    func addComment(_ body: String, in repository: RepositoryPath, number: Int) async throws {
        try await client.sendRaw(
            .post, client.url(pullRequestsPath(repository) + "/\(number)/comments"), json: ["content": ["raw": body]]
        )
    }

    func review(_ verdict: ReviewVerdict, body: String, in repository: RepositoryPath, number: Int) async throws {
        let base = pullRequestsPath(repository) + "/\(number)"
        switch verdict {
        case .approve:
            try await client.sendRaw(.post, client.url(base + "/approve"))
        case .requestChanges:
            try await client.sendRaw(.post, client.url(base + "/request-changes"))
        case .comment:
            break
        }
        if !body.isEmpty {
            try await addComment(body, in: repository, number: number)
        }
    }

    func merge(in repository: RepositoryPath, number: Int, method: MergeMethod, expectedHead: String?) async throws {
        let strategy = switch method {
        case .merge: "merge_commit"
        case .squash: "squash"
        case .rebase: "fast_forward"
        }
        try await client.sendRaw(
            .post, client.url(pullRequestsPath(repository) + "/\(number)/merge"),
            json: ["type": "pullrequest", "merge_strategy": strategy]
        )
    }

    func setOpen(_ isOpen: Bool, in repository: RepositoryPath, number: Int) async throws {
        guard !isOpen else {
            throw HostingError.unsupported("Bitbucket cannot reopen a declined pull request.")
        }
        try await client.sendRaw(.post, client.url(pullRequestsPath(repository) + "/\(number)/decline"))
    }

    func createPullRequest(_ draft: NewPullRequestDraft, in repository: RepositoryPath) async throws -> PullRequest {
        var source: [String: Any] = ["branch": ["name": draft.head]]
        if let owner = draft.headOwner {
            source["repository"] = ["full_name": "\(owner)/\(repository.name)"]
        }
        let json: [String: Any] = [
            "title": draft.title, "description": draft.body, "draft": draft.isDraft,
            "source": source, "destination": ["branch": ["name": draft.base]]
        ]
        return try await client.send(.post, client.url(pullRequestsPath(repository)), json: json, as: BitbucketPullRequest.self)
            .value.pullRequest
    }

    func headReference(number: Int) -> String? {
        nil
    }

    // MARK: Requests

    private func pullRequestsPath(_ repository: RepositoryPath) -> String {
        "/repositories/\(Self.segment(repository.owner))/\(Self.segment(repository.name))/pullrequests"
    }

    /// Every page of a list, following each page's `next`.
    private func all<Item: Decodable>(_ url: URL, as type: Item.Type) async throws -> [Item] {
        var items: [Item] = []
        var next: URL? = url
        while let url = next {
            let page = try await client.send(.get, url, as: Paged<Item>.self).value
            items += page.values
            next = page.next
        }
        return items
    }

    static func segment(_ value: String) -> String {
        GitHubService.segment(value)
    }

    /// A string in Bitbucket's filter language: in double quotes, with
    /// quotes and backslashes escaped.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The slug Bitbucket would make of a name: lower case, spaces as dashes.
    static func slug(for name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// One status for many: any failure fails, anything running is pending.
    static func summarize(_ states: [String?]) -> CheckStatus? {
        let states = states.compactMap { $0?.uppercased() }
        guard !states.isEmpty else { return nil }
        if states.contains("FAILED") { return .failure }
        if states.contains("INPROGRESS") { return .pending }
        if states.allSatisfy({ $0 == "SUCCESSFUL" }) { return .success }
        return states.contains("SUCCESSFUL") ? .success : .neutral
    }
}

// MARK: Shapes

extension BitbucketService {
    struct Paged<Item: Decodable>: Decodable {
        var values: [Item]
        var next: URL?

        var nextCursor: PageCursor? { next.map(PageCursor.url) }
    }

    struct Link: Decodable {
        var href: String?
    }

    struct Account: Decodable {
        struct Links: Decodable {
            var avatar: Link?
        }

        var username: String?
        var nickname: String?
        var display_name: String?
        var account_id: String?
        var uuid: String?
        var links: Links?

        var hostingUser: HostingUser {
            HostingUser(
                login: username ?? nickname ?? display_name ?? "",
                name: display_name,
                avatarURL: links?.avatar?.href.flatMap(URL.init(string:)),
                serviceID: uuid
            )
        }
    }

    struct Workspace: Decodable {
        var slug: String
        var name: String?
    }

    struct WorkspacePermission: Decodable {
        var workspace: Workspace?
    }

    struct Repo: Decodable {
        struct Branch: Decodable {
            var name: String?
        }

        struct Links: Decodable {
            struct Clone: Decodable {
                var name: String?
                var href: String?
            }

            var clone: [Clone]?
            var html: Link?
        }

        var full_name: String
        var description: String?
        var is_private: Bool?
        var mainbranch: Branch?
        var links: Links?
        var updated_on: Date?

        var hostingRepository: HostingRepository? {
            guard let path = RepositoryPath(full_name) else { return nil }
            let clones = links?.clone ?? []
            let https = clones.first { $0.name == "https" }?.href.map(BitbucketService.withoutUsername)
                ?? "https://bitbucket.org/\(full_name).git"
            return HostingRepository(
                path: path, description: description.flatMap { $0.isEmpty ? nil : $0 }, isPrivate: is_private ?? true,
                defaultBranch: mainbranch?.name, httpsURL: https,
                sshURL: clones.first { $0.name == "ssh" }?.href ?? "git@bitbucket.org:\(full_name).git",
                webURL: links?.html?.href.flatMap(URL.init(string:)), updatedAt: updated_on
            )
        }
    }

    /// `https://user@bitbucket.org/…` without the user, whose name would
    /// otherwise stick to the remote.
    static func withoutUsername(_ url: String) -> String {
        guard var components = URLComponents(string: url), components.user != nil else { return url }
        components.user = nil
        components.password = nil
        return components.string ?? url
    }

    struct BitbucketPullRequest: Decodable {
        struct Side: Decodable {
            struct Branch: Decodable {
                var name: String?
            }

            struct Commit: Decodable {
                var hash: String?
            }

            struct Repository: Decodable {
                var full_name: String?
            }

            var branch: Branch?
            var commit: Commit?
            var repository: Repository?

            var branchReference: PullRequestBranch {
                PullRequestBranch(
                    name: branch?.name ?? "", sha: commit?.hash,
                    repository: repository?.full_name.map { name in
                        RepositoryReference(
                            path: RepositoryPath(name), httpsURL: "https://bitbucket.org/\(name).git",
                            sshURL: "git@bitbucket.org:\(name).git"
                        )
                    }
                )
            }
        }

        struct Summary: Decodable {
            var raw: String?
        }

        struct Participant: Decodable {
            var role: String?
            var approved: Bool?
            var state: String?
        }

        struct Links: Decodable {
            var html: Link?
        }

        var id: Int
        var title: String?
        var description: String?
        var summary: Summary?
        var state: String?
        var draft: Bool?
        var author: Account?
        var source: Side?
        var destination: Side?
        var created_on: Date?
        var updated_on: Date?
        var links: Links?
        var comment_count: Int?
        var participants: [Participant]?

        var pullRequest: PullRequest {
            let participants = participants ?? []
            let review: ReviewState? = if participants.contains(where: { $0.state == "changes_requested" }) {
                .changesRequested
            } else if participants.contains(where: { $0.approved == true || $0.state == "approved" }) {
                .approved
            } else {
                nil
            }
            let pullRequestState: PullRequestState = switch state?.uppercased() {
            case "MERGED": .merged
            case "DECLINED", "SUPERSEDED": .closed
            default: .open
            }
            return PullRequest(
                number: id,
                title: title ?? "",
                body: description ?? summary?.raw ?? "",
                author: author?.hostingUser,
                state: pullRequestState,
                isDraft: draft ?? false,
                head: source?.branchReference ?? PullRequestBranch(name: ""),
                base: destination?.branchReference ?? PullRequestBranch(name: ""),
                createdAt: created_on,
                updatedAt: updated_on,
                webURL: links?.html?.href.flatMap(URL.init(string:)),
                review: review,
                commentCount: comment_count
            )
        }
    }

    struct Status: Decodable {
        var state: String?
    }

    struct CommitItem: Decodable {
        struct Author: Decodable {
            struct User: Decodable {
                var display_name: String?
            }

            var raw: String?
            var user: User?
        }

        var hash: String
        var message: String?
        var author: Author?
        var date: Date?

        var pullRequestCommit: PullRequestCommit {
            // `raw` is `Name <email>`; the name is what shows.
            let rawName = author?.raw.map { raw in
                raw.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
            }
            return PullRequestCommit(
                sha: hash, message: message ?? "", authorName: author?.user?.display_name ?? rawName, date: date
            )
        }
    }

    struct DiffStat: Decodable {
        struct File: Decodable {
            var path: String?
        }

        var status: String?
        var new: File?
        var old: File?
        var lines_added: Int?
        var lines_removed: Int?

        var pullRequestFile: PullRequestFile? {
            guard let path = new?.path ?? old?.path else { return nil }
            let fileStatus: PullRequestFile.Status = switch status {
            case "added": .added
            case "removed": .deleted
            case "renamed": .renamed
            case "modified": .modified
            default: .other
            }
            return PullRequestFile(
                path: path, previousPath: fileStatus == .renamed ? old?.path : nil, status: fileStatus,
                additions: lines_added, deletions: lines_removed
            )
        }
    }

    struct Comment: Decodable {
        struct Content: Decodable {
            var raw: String?
        }

        struct Inline: Decodable {
            var path: String?
            var to: Int?
            var from: Int?
        }

        var id: Int
        var content: Content?
        var user: Account?
        var created_on: Date?
        var deleted: Bool?
        var inline: Inline?

        var comment: PullRequestComment? {
            guard deleted != true else { return nil }
            let kind: PullRequestComment.Kind = if let path = inline?.path {
                .lineComment(path: path, line: inline?.to ?? inline?.from)
            } else {
                .comment
            }
            return PullRequestComment(
                id: "c\(id)", author: user?.hostingUser, body: content?.raw ?? "", createdAt: created_on, kind: kind
            )
        }
    }
}
