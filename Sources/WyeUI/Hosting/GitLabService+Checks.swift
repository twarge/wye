import Foundation

/// A commit's checks on GitLab: the pipelines run for it, and their jobs.
/// A commit can have several pipelines: one for its branch, one for a merge
/// request, one for a tag, and a new one each time any is run again. The
/// newest for each reference is the one that counts.
extension GitLabService {
    /// One request's worth. GraphQL, where each commit is a field of the
    /// query, as the REST API has no way to ask about several: GitLab
    /// scores a query's complexity and refuses those over 200 without an
    /// account and 250 with one, and each commit adds 7.
    static let checkBatchSize = 25
    /// How many pipelines of one commit are looked at, newest first.
    static let pipelinesPerCommit = 10
    /// How many of a commit's pipelines have their jobs listed.
    static let detailedPipelines = 5

    /// GraphQL lives beside the REST API: `/api/graphql` next to `/api/v4`.
    var graphQLURL: URL {
        var base = client.apiBase.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v4") { base.removeLast(3) }
        return URL(string: base + "/graphql")!
    }

    func checkStatuses(in repository: RepositoryPath, commits: [String]) async throws -> [String: CheckStatus] {
        // Hashes go into the query's text: only what is one.
        let commits = commits.filter(GitHubService.isHash)
        guard !commits.isEmpty else { return [:] }
        do {
            return try await pipelineStatuses(in: repository, commits: commits)
        } catch HostingError.rejected(let message) where commits.count > 1 && Self.isTooMuchToAsk(message) {
            // An instance with a lower limit than gitlab.com's: half at a time.
            let half = commits.count / 2
            let first = try await checkStatuses(in: repository, commits: Array(commits[..<half]))
            let second = try await checkStatuses(in: repository, commits: Array(commits[half...]))
            return first.merging(second) { first, _ in first }
        }
    }

    private func pipelineStatuses(in repository: RepositoryPath, commits: [String]) async throws -> [String: CheckStatus] {
        let fields = commits.enumerated().map { index, hash in
            "c\(index): pipelines(sha: \"\(hash)\", first: \(Self.pipelinesPerCommit)) { nodes { status ref } }"
        }
        let query = "query($path: ID!) { project(fullPath: $path) { \(fields.joined(separator: " ")) } }"
        let response = try await client.send(
            .post, graphQLURL, json: ["query": query, "variables": ["path": repository.fullPath]],
            as: GraphQLResponse<PipelineBatch>.self
        ).value
        if let message = response.errors?.first?.message, response.data?.project == nil {
            throw HostingError.rejected(message: message)
        }
        // No project: it is gone, or the account may not see it.
        guard let project = response.data?.project else { throw HostingError.notFound(host: client.host) }
        var statuses: [String: CheckStatus] = [:]
        for (index, hash) in commits.enumerated() {
            let pipelines = (project["c\(index)"]??.nodes ?? []).compactMap { $0 }
            statuses[hash] = Self.overallStatus(of: pipelines.map { (ref: $0.ref, status: $0.status ?? "") })
        }
        return statuses
    }

    static func isTooMuchToAsk(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("complexity") || message.localizedCaseInsensitiveContains("too large")
    }

    /// One status for a commit's pipelines, newest first: of the newest
    /// for each reference, failed if any failed, running while any runs.
    static func overallStatus(of pipelines: [(ref: String?, status: String)]) -> CheckStatus? {
        var seen: Set<String?> = []
        let newest = pipelines.filter { seen.insert($0.ref).inserted }
        return CheckStatus.merged(newest.map { checkStatus($0.status.lowercased()) })
    }

    func checks(in repository: RepositoryPath, commit: String) async throws -> CommitChecks {
        guard GitHubService.isHash(commit) else { return CommitChecks() }
        let project = "/projects/\(Self.project(repository.fullPath))"
        let listed = try await client.send(
            .get, client.url(project + "/pipelines", query: ["sha": commit, "per_page": "20"]), as: [Pipeline].self
        ).value
        var seen: Set<String?> = []
        let newest = listed.filter { seen.insert($0.ref).inserted }
        guard !newest.isEmpty else { return CommitChecks() }
        let detailed = Array(newest.prefix(Self.detailedPipelines))
        // Each pipeline's jobs, together; one that cannot be listed still
        // shows as the pipeline itself.
        let jobs = await withTaskGroup(of: (String, [Job]).self) { group in
            for pipeline in detailed {
                let url = client.url(project + "/pipelines/\(pipeline.id.value)/jobs", query: ["per_page": "100"])
                group.addTask { (pipeline.id.value, (try? await all(url, as: Job.self)) ?? []) }
            }
            var byPipeline: [String: [Job]] = [:]
            for await (id, jobs) in group { byPipeline[id] = jobs }
            return byPipeline
        }
        var runs: [CheckRun] = []
        for pipeline in newest {
            // The stage alone names a job's group while one pipeline is all there is.
            let prefix = newest.count > 1 ? Self.referenceTitle(pipeline.ref) + " · " : ""
            let listed = (jobs[pipeline.id.value] ?? []).sorted { $0.order < $1.order }
            if listed.isEmpty {
                runs.append(pipeline.run(group: newest.count > 1 ? Self.referenceTitle(pipeline.ref) : nil))
            } else {
                runs += listed.map { $0.run(group: prefix + ($0.stage ?? "Jobs")) }
            }
        }
        return CommitChecks(
            status: CheckStatus.merged(newest.map { Self.checkStatus(($0.status ?? "").lowercased()) }), runs: runs
        )
    }

    /// A pipeline's reference as people know it: the branch or tag, `!12`
    /// for a merge request's own pipeline.
    static func referenceTitle(_ ref: String?) -> String {
        guard let ref, !ref.isEmpty else { return "Pipeline" }
        let prefix = "refs/merge-requests/"
        guard ref.hasPrefix(prefix) else { return ref }
        let parts = ref.dropFirst(prefix.count).split(separator: "/")
        guard let number = parts.first else { return ref }
        // `head` is the request's branch; `merge` and `train` its results.
        let kind = parts.dropFirst().first.map(String.init) ?? "head"
        return "!\(number)" + (kind == "head" ? "" : " \(kind)")
    }

    /// A job's status and what to say beside it. A job allowed to fail
    /// does not fail its pipeline, so it does not count as a failure here.
    static func jobStatus(_ status: String?, allowsFailure: Bool) -> (CheckStatus, String?) {
        switch status?.lowercased() {
        case "success": (.success, nil)
        case "failed": allowsFailure ? (.neutral, "Failed, Allowed") : (.failure, nil)
        case "running": (.pending, "Running")
        case "pending": (.pending, "Queued")
        case "created": (.pending, "Not Started")
        case "waiting_for_resource": (.pending, "Waiting")
        case "preparing": (.pending, "Preparing")
        case "scheduled": (.pending, "Scheduled")
        case "canceling": (.pending, "Cancelling")
        case "canceled": (.neutral, "Cancelled")
        case "skipped": (.neutral, "Skipped")
        case "manual": (.neutral, "Manual")
        default: (.neutral, nil)
        }
    }

    // MARK: Shapes

    struct GraphQLResponse<Value: Decodable>: Decodable {
        struct Failure: Decodable {
            var message: String?
        }

        var data: Value?
        var errors: [Failure]?
    }

    struct PipelineBatch: Decodable {
        struct Connection: Decodable {
            struct Node: Decodable {
                var status: String?
                var ref: String?
            }

            var nodes: [Node?]?
        }

        /// By the alias each commit was asked under.
        var project: [String: Connection?]?
    }

    struct Pipeline: Decodable {
        var id: FlexibleID
        var iid: Int?
        var ref: String?
        var status: String?
        var name: String?
        var web_url: String?
        var created_at: Date?
        var updated_at: Date?

        /// The pipeline as one check, where its jobs are not listed: one
        /// another service reported, or one with none yet.
        func run(group: String?) -> CheckRun {
            let (status, detail) = GitLabService.jobStatus(status, allowsFailure: false)
            return CheckRun(
                id: "p\(id.value)", name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Pipeline #\(iid.map(String.init) ?? id.value)",
                group: group, status: status, detail: detail, startedAt: created_at,
                completedAt: status == .pending ? nil : updated_at, url: web_url.flatMap(URL.init(string:))
            )
        }
    }

    struct Job: Decodable {
        var id: FlexibleID
        var name: String?
        var stage: String?
        var status: String?
        var allow_failure: Bool?
        var started_at: Date?
        var finished_at: Date?
        var web_url: String?

        /// The order jobs were made in, which is mostly that of their stages.
        var order: Int { Int(id.value) ?? 0 }

        func run(group: String) -> CheckRun {
            let (status, detail) = GitLabService.jobStatus(status, allowsFailure: allow_failure ?? false)
            return CheckRun(
                id: "j\(id.value)", name: name ?? "Job \(id.value)", group: group, status: status, detail: detail,
                startedAt: started_at, completedAt: finished_at, url: web_url.flatMap(URL.init(string:))
            )
        }
    }
}
