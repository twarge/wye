import Foundation

/// What Wye asks of a hosting service. One implementation per service,
/// each over a `HostingClient`, so all of them can be tested against
/// recorded responses.
///
/// Repositories are named by their path on the service; pull requests by
/// their number (GitLab's `iid`).
protocol HostingService: Sendable {
    var kind: HostingKind { get }
    var capabilities: HostingCapabilities { get }

    /// Who the token belongs to. Signing in calls this to check the token.
    func currentUser() async throws -> HostingUser

    // MARK: Repositories

    /// The account's repositories, newest activity first, narrowed by
    /// `query` when it is not empty.
    func repositories(_ filter: RepositoryListFilter, query: String, page: PageCursor?) async throws -> Page<HostingRepository>
    /// The account and the organizations, groups or workspaces it can
    /// make repositories in.
    func owners() async throws -> [HostingOwner]
    func createRepository(_ draft: NewRepositoryDraft) async throws -> HostingRepository

    // MARK: Pull requests

    func pullRequests(in repository: RepositoryPath, filter: PullRequestFilter, page: PageCursor?) async throws -> Page<PullRequest>
    /// One pull request, with what the list leaves out: checks, reviews,
    /// whether it can merge.
    func pullRequest(in repository: RepositoryPath, number: Int) async throws -> PullRequest
    func commits(in repository: RepositoryPath, number: Int) async throws -> [PullRequestCommit]
    func changedFiles(in repository: RepositoryPath, number: Int) async throws -> [PullRequestFile]
    /// Comments and reviews, oldest first.
    func conversation(in repository: RepositoryPath, number: Int) async throws -> [PullRequestComment]
    func addComment(_ body: String, in repository: RepositoryPath, number: Int) async throws
    func review(_ verdict: ReviewVerdict, body: String, in repository: RepositoryPath, number: Int) async throws
    /// Merges, refusing if the head moved past `expectedHead` when given.
    func merge(
        in repository: RepositoryPath, number: Int, method: MergeMethod, expectedHead: String?
    ) async throws
    /// Closes (declines, on Bitbucket) or reopens.
    func setOpen(_ isOpen: Bool, in repository: RepositoryPath, number: Int) async throws
    func createPullRequest(_ draft: NewPullRequestDraft, in repository: RepositoryPath) async throws -> PullRequest

    /// The reference on the base repository that holds a pull request's
    /// head, to fetch when its own repository cannot be reached:
    /// `refs/pull/12/head`. `nil` where there is none.
    func headReference(number: Int) -> String?

    // MARK: Checks

    /// How the checks of commits stand overall, by full hash, in one
    /// request: at most `capabilities.checkBatchSize` commits. A commit
    /// nothing was run for, or one the service does not have, is left out.
    func checkStatuses(in repository: RepositoryPath, commits: [String]) async throws -> [String: CheckStatus]
    /// Every check of one commit: the jobs of its workflows or pipelines,
    /// and the statuses other services reported for it.
    func checks(in repository: RepositoryPath, commit: String) async throws -> CommitChecks
}

extension HostingService {
    // Where a commit's checks are not read, it has none.
    func checkStatuses(in repository: RepositoryPath, commits: [String]) async throws -> [String: CheckStatus] { [:] }
    func checks(in repository: RepositoryPath, commit: String) async throws -> CommitChecks { CommitChecks() }
}

/// Where each service's API lives.
enum HostingEndpoints {
    /// The API's base for a service on a host: `https://api.github.com`
    /// for github.com, `https://host/api/v3` for GitHub Enterprise,
    /// `https://host/api/v4` for GitLab, `https://host/api/v1` for Gitea,
    /// and Bitbucket Cloud's one API.
    static func apiBase(kind: HostingKind, host: String, scheme: String = "https") -> URL {
        let host = host.lowercased()
        let string = switch kind {
        case .github: host == "github.com" ? "https://api.github.com" : "\(scheme)://\(host)/api/v3"
        case .gitlab: "\(scheme)://\(host)/api/v4"
        case .bitbucket: "https://api.bitbucket.org/2.0"
        case .gitea: "\(scheme)://\(host)/api/v1"
        }
        return URL(string: string)!
    }

    /// The site itself: `https://github.com`.
    static func webBase(host: String, scheme: String = "https") -> URL {
        URL(string: "\(scheme)://\(host.lowercased())")!
    }

    /// The page where a personal access token is made, with the scopes
    /// Wye needs chosen where the service lets a link choose them.
    static func newTokenPage(kind: HostingKind, host: String, scheme: String = "https") -> URL? {
        let base = "\(scheme)://\(host.lowercased())"
        return switch kind {
        case .github: URL(string: base + "/settings/tokens/new?scopes=repo,read:org&description=Wye")
        case .gitlab: URL(string: base + "/-/user_settings/personal_access_tokens?name=Wye&scopes=api,write_repository")
        case .bitbucket: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")
        case .gitea: URL(string: base + "/user/settings/applications")
        }
    }

    /// What a token must be allowed, in the service's own words.
    static func tokenScopes(kind: HostingKind) -> String {
        switch kind {
        case .github:
            "A classic token with the “repo” and “read:org” scopes, or a fine-grained token with read and write "
                + "access to Contents, Pull requests and Administration (to publish), and read access to Metadata and Commit statuses."
        case .gitlab:
            "The “api” and “write_repository” scopes."
        case .bitbucket:
            "An Atlassian API token for Bitbucket with the scopes read:user, read:workspace, read:repository, "
                + "write:repository, admin:repository, read:pullrequest and write:pullrequest. Bitbucket also "
                + "needs the email address of your Atlassian account."
        case .gitea:
            "Read and write access to “repository” and “issue”, and read access to “user” and “organization”."
        }
    }
}

/// Makes the service for an account.
enum HostingServices {
    static func service(
        kind: HostingKind, host: String, scheme: String = "https", user: HostingUser?,
        tokens: any TokenSource, transport: any HTTPTransport
    ) -> any HostingService {
        let client = HostingClient(
            apiBase: HostingEndpoints.apiBase(kind: kind, host: host, scheme: scheme),
            host: host, tokens: tokens, transport: transport
        )
        return switch kind {
        case .github: GitHubService(client: client, user: user)
        case .gitlab: GitLabService(client: client, user: user)
        case .bitbucket: BitbucketService(client: client, user: user)
        case .gitea: GiteaService(client: client, user: user)
        }
    }
}

extension HostedRepository {
    /// The repository's path on its service: `owner/project`, or
    /// `group/subgroup/project` on GitLab.
    var repositoryPath: RepositoryPath? {
        RepositoryPath(url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// The host, with its port when it has one: what accounts are kept for.
    var host: String {
        (url.host(percentEncoded: false) ?? "").lowercased() + (url.port.map { ":\($0)" } ?? "")
    }

    /// `host/owner/project`, the same for every address of a repository,
    /// HTTPS or SSH. Choices of account per repository are kept by it.
    var key: String {
        host + "/" + (repositoryPath?.fullPath.lowercased() ?? "")
    }
}
