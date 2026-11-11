import Foundation

/// The hosting services Twig talks to beyond git itself: accounts,
/// repositories and pull requests.
enum HostingKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case github
    case gitlab
    case bitbucket
    /// Gitea and Forgejo, whose APIs are the same for everything Twig uses.
    case gitea

    var id: Self { self }

    var title: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucket: "Bitbucket"
        case .gitea: "Gitea or Forgejo"
        }
    }

    /// The name a menu item uses: Publish to GitHub….
    var shortTitle: String {
        switch self {
        case .gitea: "Gitea"
        default: title
        }
    }

    /// What the service calls a pull request.
    var pullRequestTerm: String {
        self == .gitlab ? "Merge Request" : "Pull Request"
    }

    /// `#12` on most services, `!12` for a GitLab merge request.
    func reference(_ number: Int) -> String {
        (self == .gitlab ? "!" : "#") + String(number)
    }

    /// The public instance, offered first when adding an account.
    var defaultHost: String {
        switch self {
        case .github: "github.com"
        case .gitlab: "gitlab.com"
        case .bitbucket: "bitbucket.org"
        case .gitea: "codeberg.org"
        }
    }

    /// Whether the service runs on hosts other than its own: GitHub
    /// Enterprise, self-managed GitLab, any Gitea or Forgejo.
    var isSelfHostable: Bool {
        self != .bitbucket
    }

    init?(_ kind: HostedRepository.Kind) {
        switch kind {
        case .github: self = .github
        case .gitlab: self = .gitlab
        case .bitbucket: self = .bitbucket
        case .gitea: self = .gitea
        case .sourcehut, .other: return nil
        }
    }
}

/// A person on a hosting service.
struct HostingUser: Hashable, Sendable, Codable {
    var login: String
    var name: String?
    var avatarURL: URL?
    /// Bitbucket's account id, which its queries need in place of a name.
    var serviceID: String?

    var displayName: String {
        guard let name, !name.isEmpty else { return login }
        return name
    }
}

/// Where a repository lives on its service: `owner/name`, where GitLab's
/// owner may be a nested group (`group/subgroup`).
struct RepositoryPath: Hashable, Sendable, Codable, CustomStringConvertible {
    var owner: String
    var name: String

    init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// From `owner/name` or `group/subgroup/name`.
    init?(_ fullPath: String) {
        let parts = fullPath.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        owner = parts.dropLast().joined(separator: "/")
        name = parts[parts.count - 1]
    }

    var fullPath: String { owner + "/" + name }
    var description: String { fullPath }
}

/// A repository listed by a service.
struct HostingRepository: Identifiable, Hashable, Sendable {
    var path: RepositoryPath
    var description: String?
    var isPrivate: Bool
    var defaultBranch: String?
    var httpsURL: String
    var sshURL: String?
    var webURL: URL?
    var updatedAt: Date?

    var id: String { path.fullPath }

    /// The address to clone, as the preference asks.
    func cloneURL(preferSSH: Bool) -> String {
        preferSSH ? (sshURL ?? httpsURL) : httpsURL
    }
}

/// Which repositories a list shows.
enum RepositoryListFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// The account's own and those it is a member of.
    case member
    case starred

    var id: Self { self }

    var title: String {
        switch self {
        case .member: "Yours"
        case .starred: "Starred"
        }
    }
}

/// Somewhere a new repository can be made: the account itself, or an
/// organization, group or workspace it belongs to.
struct HostingOwner: Identifiable, Hashable, Sendable {
    var login: String
    var displayName: String
    /// The account's own namespace, rather than an organization's.
    var isUser: Bool
    /// GitLab's namespace id, which its API takes in place of a path.
    var serviceID: String?

    var id: String { login }
}

/// A repository to make with Publish.
struct NewRepositoryDraft: Hashable, Sendable {
    var owner: HostingOwner
    var name: String
    var description: String
    var isPrivate: Bool
}

/// One page of a list, and where the next one starts.
struct Page<Item: Sendable>: Sendable {
    var items: [Item]
    var next: PageCursor?
}

/// Where a list's next page starts: a URL the service gave, a page number,
/// or an opaque cursor (GitHub's GraphQL).
enum PageCursor: Hashable, Sendable {
    case url(URL)
    case number(Int)
    case token(String)
}

// MARK: Pull requests

enum PullRequestState: String, Hashable, Sendable, Codable {
    case open
    case closed
    case merged
}

/// What a pull request list shows.
enum PullRequestFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case open
    case closed
    case merged
    /// Open ones the account opened.
    case mine
    /// Open ones the account is asked to review.
    case reviewRequested

    var id: Self { self }

    var title: String {
        switch self {
        case .open: "Open"
        case .closed: "Closed"
        case .merged: "Merged"
        case .mine: "Mine"
        case .reviewRequested: "Review Requested"
        }
    }
}

/// How a pull request's checks, or CI pipeline, stand overall.
enum CheckStatus: String, Hashable, Sendable {
    case pending
    case success
    case failure
    /// Skipped, cancelled or neutral: neither passed nor failed.
    case neutral
}

/// Where a pull request's reviews stand.
enum ReviewState: String, Hashable, Sendable {
    case approved
    case changesRequested
    /// Reviews are wanted and none has approved yet.
    case reviewRequired
}

/// One side of a pull request: the branch, the commit it was at, and the
/// repository it is on (another one for a contribution from a copy).
struct PullRequestBranch: Hashable, Sendable {
    var name: String
    var sha: String?
    var repository: RepositoryReference?
}

/// A repository named by a pull request, with its addresses where the
/// service gives them.
struct RepositoryReference: Hashable, Sendable {
    var path: RepositoryPath?
    var httpsURL: String?
    var sshURL: String?
}

struct PullRequest: Identifiable, Hashable, Sendable {
    var number: Int
    var title: String
    var body: String
    var author: HostingUser?
    var state: PullRequestState
    var isDraft: Bool
    var head: PullRequestBranch
    var base: PullRequestBranch
    var createdAt: Date?
    var updatedAt: Date?
    var webURL: URL?
    /// `nil` where the list did not say; the detail fills it in.
    var checks: CheckStatus?
    var review: ReviewState?
    var commentCount: Int?
    /// Whether it can merge without conflicts, where the service says.
    var isMergeable: Bool?

    var id: Int { number }

    /// Whether the head is on another repository than the base.
    var isFromOtherRepository: Bool {
        guard let head = head.repository?.path, let base = base.repository?.path else { return false }
        return head.fullPath.lowercased() != base.fullPath.lowercased()
    }
}

struct PullRequestCommit: Identifiable, Hashable, Sendable {
    var sha: String
    var message: String
    var authorName: String?
    var date: Date?

    var id: String { sha }
    var subject: String { message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }
}

struct PullRequestFile: Identifiable, Hashable, Sendable {
    enum Status: String, Hashable, Sendable {
        case added, modified, deleted, renamed, other
    }

    var path: String
    var previousPath: String?
    var status: Status
    var additions: Int?
    var deletions: Int?

    var id: String { path }
}

/// A comment in a pull request's conversation, or a review.
struct PullRequestComment: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case comment
        case review(ReviewVerdict?)
        /// A comment on a line of the diff, shown with its path.
        case lineComment(path: String, line: Int?)
    }

    var id: String
    var author: HostingUser?
    var body: String
    var createdAt: Date?
    var kind: Kind
}

/// A reviewer's judgement.
enum ReviewVerdict: String, Hashable, Sendable {
    case approve
    case requestChanges
    case comment
}

enum MergeMethod: String, CaseIterable, Identifiable, Hashable, Sendable {
    case merge
    case squash
    case rebase

    var id: Self { self }

    var title: String {
        switch self {
        case .merge: "Merge Commit"
        case .squash: "Squash and Merge"
        case .rebase: "Rebase and Merge"
        }
    }
}

/// A pull request to open.
struct NewPullRequestDraft: Hashable, Sendable {
    var base: String
    var head: String
    /// The repository the head branch is on, when it is not the base's.
    var headOwner: String?
    var title: String
    var body: String
    var isDraft: Bool
}

/// What a service can do with pull requests, so the interface offers
/// only that.
struct HostingCapabilities: Hashable, Sendable {
    var mergeMethods: [MergeMethod]
    var canApprove: Bool
    var canRequestChanges: Bool
    var supportsDrafts: Bool
    /// Bitbucket cannot reopen a declined pull request.
    var canReopen: Bool
    /// Whether the service has a fetchable reference for a pull request's
    /// head on the base repository (`refs/pull/12/head`).
    var hasHeadReference: Bool
}
