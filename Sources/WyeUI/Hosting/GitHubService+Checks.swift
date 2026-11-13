import Foundation

/// A commit's checks on GitHub: check runs (Actions jobs among them) and
/// the statuses other services report, which GitHub rolls up into one
/// state per commit. Both through GraphQL, where one request can ask
/// about many commits.
extension GitHubService {
    /// One request's worth: each commit is a field of the query, and a
    /// hundred of them cost one point of the rate limit.
    static let checkBatchSize = 100
    /// A page of one commit's checks, and how many pages are read.
    static let checkPageSize = 100
    static let checkPageLimit = 3

    func checkStatuses(in repository: RepositoryPath, commits: [String]) async throws -> [String: CheckStatus] {
        // Hashes go into the query's text: only what is one.
        let commits = commits.filter(Self.isHash)
        guard !commits.isEmpty else { return [:] }
        let fields = commits.enumerated().map { index, hash in
            "c\(index): object(oid: \"\(hash)\") { ... on Commit { statusCheckRollup { state } } }"
        }
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) { \(fields.joined(separator: " ")) }
        }
        """
        let data = try await graphQL(query, variables: ["owner": repository.owner, "name": repository.name], as: CheckBatch.self)
        guard let objects = data.repository else { throw HostingError.notFound(host: client.host) }
        var statuses: [String: CheckStatus] = [:]
        for (index, hash) in commits.enumerated() {
            // No object: not pushed here. No rollup: nothing ran for it.
            if let state = objects["c\(index)"]??.statusCheckRollup?.state {
                statuses[hash] = Self.checkStatus(state)
            }
        }
        return statuses
    }

    func checks(in repository: RepositoryPath, commit: String) async throws -> CommitChecks {
        guard Self.isHash(commit) else { return CommitChecks() }
        var checks = CommitChecks()
        var after: String?
        for _ in 0..<Self.checkPageLimit {
            var variables: [String: Any] = [
                "owner": repository.owner, "name": repository.name, "oid": commit, "first": Self.checkPageSize
            ]
            if let after { variables["after"] = after }
            let data = try await graphQL(Self.checksQuery, variables: variables, as: CheckDetail.self)
            guard let found = data.repository else { throw HostingError.notFound(host: client.host) }
            guard let rollup = found.object?.statusCheckRollup else { break }
            checks.status = Self.checkStatus(rollup.state)
            let offset = checks.runs.count
            checks.runs += (rollup.contexts?.nodes ?? []).enumerated().compactMap { index, node in
                node?.run(at: offset + index)
            }
            guard rollup.contexts?.pageInfo?.hasNextPage == true, let cursor = rollup.contexts?.pageInfo?.endCursor else { break }
            after = cursor
        }
        return checks
    }

    /// Whether a string is a full object name: forty hexadecimal digits,
    /// or sixty-four for SHA-256.
    static func isHash(_ string: String) -> Bool {
        (string.utf8.count == 40 || string.utf8.count == 64) && string.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }

    static let checksQuery = """
    query($owner: String!, $name: String!, $oid: GitObjectID!, $first: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        object(oid: $oid) {
          ... on Commit {
            statusCheckRollup {
              state
              contexts(first: $first, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  __typename
                  ... on CheckRun {
                    databaseId name status conclusion detailsUrl startedAt completedAt
                    checkSuite { app { name } workflowRun { workflow { name } } }
                  }
                  ... on StatusContext { context state description targetUrl createdAt }
                }
              }
            }
          }
        }
      }
    }
    """

    // MARK: Shapes

    struct CheckBatch: Decodable {
        struct Object: Decodable {
            struct Rollup: Decodable {
                var state: String
            }

            var statusCheckRollup: Rollup?
        }

        /// By the alias each commit was asked under.
        var repository: [String: Object?]?
    }

    struct CheckDetail: Decodable {
        struct Repository: Decodable {
            var object: Object?
        }

        struct Object: Decodable {
            var statusCheckRollup: Rollup?
        }

        struct Rollup: Decodable {
            var state: String
            var contexts: Contexts?
        }

        struct Contexts: Decodable {
            struct PageInfo: Decodable {
                var hasNextPage: Bool
                var endCursor: String?
            }

            var pageInfo: PageInfo?
            var nodes: [CheckContext?]?
        }

        var repository: Repository?
    }

    /// A check run or a reported status, whichever the fields say.
    struct CheckContext: Decodable {
        struct Suite: Decodable {
            struct App: Decodable {
                var name: String?
            }

            struct WorkflowRun: Decodable {
                struct Workflow: Decodable {
                    var name: String?
                }

                var workflow: Workflow?
            }

            var app: App?
            var workflowRun: WorkflowRun?
        }

        var __typename: String?
        // A check run's.
        var databaseId: Int64?
        var name: String?
        var status: String?
        var conclusion: String?
        var detailsUrl: String?
        var startedAt: Date?
        var completedAt: Date?
        var checkSuite: Suite?
        // A reported status's.
        var context: String?
        var state: String?
        var description: String?
        var targetUrl: String?
        var createdAt: Date?

        /// `index` tells apart two runs the service gave no id for.
        func run(at index: Int) -> CheckRun? {
            if let context {
                let status = GitHubService.checkStatus(state ?? "")
                return CheckRun(
                    id: "s\(index):\(context)", name: context, group: nil, status: status,
                    detail: description.flatMap { $0.isEmpty ? nil : $0 } ?? (status == .pending ? "Pending" : nil),
                    startedAt: nil, completedAt: status == .pending ? nil : createdAt,
                    url: targetUrl.flatMap(URL.init(string:))
                )
            }
            guard let name else { return nil }
            let (status, detail) = GitHubService.checkRunStatus(status: status, conclusion: conclusion)
            return CheckRun(
                id: databaseId.map { "r\($0)" } ?? "r\(index):\(name)", name: name,
                // The workflow for an Actions job; the app for any other.
                group: checkSuite?.workflowRun?.workflow?.name ?? checkSuite?.app?.name,
                status: status, detail: detail, startedAt: startedAt, completedAt: completedAt,
                url: detailsUrl.flatMap(URL.init(string:))
            )
        }
    }

    /// A check run's status and what to say beside it. One that was
    /// cancelled, timed out or wants action counts as failed, as GitHub
    /// counts it in the commit's overall state.
    static func checkRunStatus(status: String?, conclusion: String?) -> (CheckStatus, String?) {
        guard status?.uppercased() == "COMPLETED" || (status == nil && conclusion != nil) else {
            return switch status?.uppercased() {
            case "IN_PROGRESS": (.pending, "Running")
            case "QUEUED": (.pending, "Queued")
            case "WAITING": (.pending, "Waiting")
            case "REQUESTED": (.pending, "Requested")
            default: (.pending, "Pending")
            }
        }
        return switch conclusion?.uppercased() {
        case "SUCCESS": (.success, nil)
        case "FAILURE": (.failure, nil)
        case "TIMED_OUT": (.failure, "Timed Out")
        case "CANCELLED": (.failure, "Cancelled")
        case "ACTION_REQUIRED": (.failure, "Action Required")
        case "STARTUP_FAILURE": (.failure, "Failed to Start")
        case "SKIPPED": (.neutral, "Skipped")
        case "STALE": (.neutral, "Stale")
        default: (.neutral, "Neutral")
        }
    }
}
