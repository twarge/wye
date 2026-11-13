import Foundation

/// One check of a commit: a job of a workflow or pipeline, or a status
/// another service reported to the hosting service.
struct CheckRun: Identifiable, Hashable, Sendable, Codable {
    /// Its own among a commit's checks on one repository.
    var id: String
    var name: String
    /// What it is part of: the workflow on GitHub, the pipeline's stage on
    /// GitLab. `nil` for a status reported on its own.
    var group: String?
    var status: CheckStatus
    /// What the status leaves unsaid, in a word or two: Skipped, Timed
    /// Out, Queued. A reported status's own description.
    var detail: String?
    var startedAt: Date?
    var completedAt: Date?
    /// Its page on the service, or the service that reported it.
    var url: URL?

    /// How long it ran, once it has finished.
    var duration: TimeInterval? {
        guard let startedAt, let completedAt, completedAt >= startedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }
}

/// Every check of one commit on one repository of a service, and how they
/// stand overall.
struct CommitChecks: Hashable, Sendable, Codable {
    /// `nil` for a commit nothing was run for.
    var status: CheckStatus?
    var runs: [CheckRun] = []
}

extension CheckStatus {
    /// Which of two statuses says more about the whole: a failure before
    /// anything still running, that before a success, and a check that was
    /// skipped last.
    private var weight: Int {
        switch self {
        case .failure: 3
        case .pending: 2
        case .success: 1
        case .neutral: 0
        }
    }

    /// One status for several: failed if any failed, running while any still
    /// runs, passed once all that ran have passed. `nil` for none.
    static func merged(_ statuses: some Sequence<CheckStatus>) -> CheckStatus? {
        statuses.max { $0.weight < $1.weight }
    }

    /// How a commit's checks stand, as a sentence's worth.
    var summary: String {
        switch self {
        case .success: "Checks passed"
        case .failure: "Checks failed"
        case .pending: "Checks running"
        case .neutral: "Checks neutral or skipped"
        }
    }
}

/// The checks of one workflow or stage, or those with none.
struct CheckGroup: Identifiable, Hashable {
    var title: String?
    var runs: [CheckRun]

    var id: String { title ?? "" }
}

extension Collection where Element == CheckRun {
    /// The runs under their groups, in the order the groups first appear.
    /// Groups with a failure come first, then those still running: what
    /// the reader came to find.
    var grouped: [CheckGroup] {
        var groups: [CheckGroup] = []
        var places: [String?: Int] = [:]
        for run in self {
            if let place = places[run.group] {
                groups[place].runs.append(run)
            } else {
                places[run.group] = groups.count
                groups.append(CheckGroup(title: run.group, runs: [run]))
            }
        }
        func urgency(_ group: CheckGroup) -> Int {
            switch CheckStatus.merged(group.runs.map(\.status)) {
            case .failure: 0
            case .pending: 1
            default: 2
            }
        }
        return groups.enumerated()
            .sorted { (urgency($0.element), $0.offset) < (urgency($1.element), $1.offset) }
            .map(\.element)
    }

    /// How many checks there are and how they went, for the line above
    /// them: "All 12 checks passed", "2 of 12 checks failed".
    func tally(overall status: CheckStatus?) -> String {
        let total = count
        let noun = total == 1 ? "check" : "checks"
        func counted(_ wanted: CheckStatus) -> Int { count { $0.status == wanted } }
        switch status ?? CheckStatus.merged(map(\.status)) {
        case nil:
            return "No checks"
        case .failure:
            let failed = counted(.failure)
            return failed > 0 && total > 0 ? "\(failed) of \(total) \(noun) failed" : "Checks failed"
        case .pending:
            let running = counted(.pending)
            return running > 0 && total > 0 ? "\(running) of \(total) \(noun) running" : "Checks running"
        case .success:
            guard total > 0 else { return "Checks passed" }
            let passed = counted(.success)
            if passed == total { return total == 1 ? "The check passed" : "All \(total) checks passed" }
            return "\(passed) of \(total) \(noun) passed"
        case .neutral:
            return total > 0 ? "\(total) \(noun) skipped or neutral" : "Checks neutral or skipped"
        }
    }
}
