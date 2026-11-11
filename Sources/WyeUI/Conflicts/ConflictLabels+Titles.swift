import GitKit

extension ConflictSideLabel {
    /// A short name for the side, for buttons: "Current", "Incoming", and
    /// for a rebase, where git's sides swap, "Upstream" and "Your Commit".
    var title: String {
        switch role {
        case .current: "Current"
        case .incoming: "Incoming"
        case .onto: "Upstream"
        case .replayed: "Your Commit"
        case .picked: "Picked"
        case .reverted: "Reverted"
        }
    }

    /// The side's title with the branch or commit it is.
    var heading: String {
        guard let what = name ?? commit.map({ $0.abbreviated() }) else { return title }
        return "\(title) · \(what)"
    }

    /// What the side holds, in a sentence.
    var explanation: String {
        let commitText = commit.map { id in
            [id.abbreviated(), summary.map { "“\($0)”" }].compactMap { $0 }.joined(separator: " ")
        }
        switch role {
        case .current:
            return name.map { "The version on “\($0)”, the branch you are on." } ?? "The version at the detached HEAD."
        case .incoming:
            if let name { return "The version on “\(name)”, being merged in." }
            return commitText.map { "The version from \($0), being brought in." } ?? "The version being brought in."
        case .onto:
            let onto = name.map { "“\($0)”" } ?? "the branch being rebased onto"
            return "The version on \(onto), with your commits replayed so far."
        case .replayed:
            let commit = commitText ?? "your commit"
            return name.map { "Your commit \(commit) from “\($0)”, being replayed." } ?? "\(commit), being replayed."
        case .picked:
            return "The version in \(commitText ?? "the commit") being cherry-picked."
        case .reverted:
            return "The version before \(commitText ?? "the commit") being reverted, which the revert goes back to."
        }
    }

    /// A label for conflict markers in the result: git's style, with the name.
    var markerLabel: String {
        name ?? commit.map { $0.abbreviated() } ?? title
    }
}

extension ConflictLabels {
    /// What the base, git's common ancestor, is for this operation.
    var baseExplanation: String {
        switch operation {
        case .merge, nil: "The version both sides started from."
        case .rebase, .cherryPick: "The version before the commit, which it changed."
        case .revert: "The version in the commit being reverted."
        }
    }
}
