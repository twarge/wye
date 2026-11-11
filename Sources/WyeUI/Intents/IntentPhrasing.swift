import Foundation
import GitKit

/// What Siri says and Shortcuts shows after an intent: one short sentence,
/// kept apart from the intents so it can be tested.
enum IntentPhrasing {
    static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }

    static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    // MARK: Pull

    /// "Pulled 3 commits into main", "Already up to date".
    /// `count` is how many commits the branch gained.
    static func pulled(_ outcome: PullOutcome, count: Int, branch: String) -> String {
        let sentence: String = switch outcome.result {
        case .upToDate:
            "Already up to date."
        case .fastForwarded:
            "Pulled \(commits(count)) into \(branch)."
        case .merged:
            "Merged \(commits(max(count - 1, 0))) into \(branch)."
        case .rebased:
            "Rebased \(branch) onto the pulled commits."
        case .conflicts(let paths):
            "The pull into \(branch) stopped on conflicts in \(files(paths.count)). Open Wye to resolve them."
        case .rebaseStopped(_, let paths):
            "The rebase of \(branch) stopped on conflicts in \(files(paths.count)). Open Wye to resolve them."
        }
        return sentence + autostashNote(outcome.autostash)
    }

    private static func autostashNote(_ autostash: AutostashResult) -> String {
        switch autostash {
        case .notNeeded, .restored:
            ""
        case .conflicted:
            " Your local changes came back with conflicts; open Wye to resolve them."
        case .notApplied, .keptForLater:
            " Your local changes are kept in a stash."
        }
    }

    // MARK: Fetch

    /// After fetching one repository: where its branch stands now.
    static func fetched(_ name: String, branch: Branch?) -> String {
        guard let branch, let upstream = branch.upstream else { return "Fetched \(name)." }
        switch (upstream.ahead, upstream.behind) {
        case (0, 0):
            return "Fetched \(name). \(branch.name) is up to date."
        case (_, 0):
            return "Fetched \(name). \(branch.name) has \(commits(upstream.ahead)) to push."
        case (0, _):
            return "Fetched \(name). \(branch.name) is \(commits(upstream.behind)) behind \(upstream.name)."
        default:
            return "Fetched \(name). \(branch.name) is \(upstream.ahead) ahead and \(upstream.behind) behind \(upstream.name)."
        }
    }

    /// After fetching every repository: how many worked, and why the first
    /// that did not failed (`failures` are sentences from ``failure(_:name:)``).
    static func fetchedAll(succeeded: Int, failures: [String]) -> String {
        let total = succeeded + failures.count
        guard total > 0 else { return "There are no repositories with remotes in Wye to fetch." }
        guard let first = failures.first else {
            return total == 1 ? "Fetched 1 repository." : "Fetched all \(total) repositories."
        }
        let others = failures.count > 1 ? " \(failures.count - 1) more could not be fetched either." : ""
        return "Fetched \(succeeded) of \(total) repositories. \(first)\(others)"
    }

    // MARK: Push

    /// After pushing `count` commits of `branch`.
    static func pushed(_ result: PushResult, branch: String, count: Int) -> String {
        let remoteBranch = result.reference.hasPrefix("refs/heads/")
            ? String(result.reference.dropFirst("refs/heads/".count)) : result.reference
        if result.setUpstream {
            return "Published \(branch) to \(result.remote)."
        }
        return "Pushed \(commits(count)) to \(result.remote)/\(remoteBranch)."
    }

    static func nothingToPush(branch: String) -> String {
        "\(branch) has nothing to push."
    }

    // MARK: Status

    /// "Horizontal is on main, 2 ahead and 1 behind, with 3 changed files."
    static func status(_ name: String, branch: String?, upstream: Branch.Upstream?, changedFiles: Int) -> String {
        let place = branch.map { "on \($0)" } ?? "not on a branch"
        let standing: String = if let upstream {
            switch (upstream.ahead, upstream.behind) {
            case (0, 0): "up to date"
            case (_, 0): "\(commits(upstream.ahead)) to push"
            case (0, _): "\(commits(upstream.behind)) behind"
            default: "\(upstream.ahead) ahead and \(upstream.behind) behind"
            }
        } else if branch != nil {
            "not published"
        } else {
            ""
        }
        let changes = changedFiles == 0 ? "no changes" : "\(files(changedFiles)) changed"
        return [ "\(name) is \(place)", standing, "with \(changes)." ]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: Failures

    /// Wye would ask the user something here; an intent cannot, so it
    /// says to open Wye.
    static func failure(_ error: any Error, name: String) -> String {
        if let error = error as? RemoteError {
            switch error {
            case .credentialsRequired(let host, _):
                return "\(host) wants a username and access token. Open Wye and run it there once to sign in."
            case .credentialsRejected(let host, _):
                return "\(host) did not accept the saved access token. Open Wye to enter a new one."
            case .unknownHostKey(let key), .hostKeyChanged(let key, _):
                return "Wye has to check the SSH host key of \(key.host) first. Open Wye and run it there."
            case .sshKeyRequired(let host, _), .sshKeysRejected(let host, _):
                return "\(host) did not accept an SSH key from Wye. Open Wye to set one up."
            default:
                break
            }
        }
        if let error = error as? GitError, error.isBlockedByLocalChanges {
            return "Local changes in \(name) are in the way. Open Wye to pull there."
        }
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "\(name): \(description)"
    }

    /// The operation Wye is already running on that repository.
    static func busy(_ name: String, activity: String) -> String {
        "Wye is already busy with \(name) (\(activity.lowercased())). Try again when it finishes."
    }
}
