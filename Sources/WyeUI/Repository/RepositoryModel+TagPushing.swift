import Foundation
import GitKit

/// A network operation that could not start because another is under way.
struct RemoteOperationBusy: LocalizedError {
    var errorDescription: String? { "Another network operation was under way." }
}

/// A new tag that did not reach every remote, said as a whole.
struct NewTagPushFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A tag pushed as it was made: where it pointed, and the remotes it reached.
struct PushedNewTag: Hashable {
    var target: OID
    var remotes: [String]
}

/// How pushing a new tag to every remote went.
struct NewTagPushOutcome {
    var pushed: [String] = []
    /// Remotes that did not get the tag, in order, with why.
    var failed: [(remote: String, reason: String)] = []
    /// Remotes not tried because the user cancelled.
    var skipped: [String] = []
}

extension RepositoryModel {
    /// The New Tag sheet's push toggle for these remotes: naming the one
    /// remote when there is only one, `nil` when there are none to push to.
    static func newTagPushTitle(remotes: [String]) -> String? {
        switch remotes.count {
        case 0: nil
        case 1: "Push to “\(remotes[0])”"
        default: "Push to All Remotes"
        }
    }

    /// Creates a tag, undoably, then pushes it to every remote when
    /// `pushing` is set, one after another. A remote that fails does not
    /// stop the others or undo the tag; the failures are told together.
    func createTag(named name: String, at commit: OID, message: String?, pushing: Bool) async {
        var created: String?
        await perform(.createTag) { created = try await $0.createTag(named: name, at: commit, message: message) }
        guard pushing, let created else { return }
        let names = remoteNames
        guard !names.isEmpty else { return }
        let target = target(of: created) ?? commit
        let outcome = await Self.pushTag(to: names) { remote in
            await self.runRemote("Pushing Tag to “\(remote)”", presentsError: false) { repository, transfer, _ in
                try await repository.pushTags([created], to: remote, credentials: CredentialStore.shared, transfer: transfer)
            }
        }
        if !outcome.pushed.isEmpty {
            remotes.pushedNewTags[created] = PushedNewTag(target: target, remotes: outcome.pushed)
        }
        if let message = Self.newTagPushFailureMessage(tag: name, outcome) {
            error = PresentedError(NewTagPushFailure(message: message))
        }
    }

    /// Runs `push` for each remote in turn, going on past failures and
    /// stopping only when the user cancels.
    static func pushTag(to remotes: [String], _ push: (String) async -> (any Error)?) async -> NewTagPushOutcome {
        var outcome = NewTagPushOutcome()
        for (index, remote) in remotes.enumerated() {
            switch await push(remote) {
            case nil:
                outcome.pushed.append(remote)
            case is CancellationError:
                outcome.skipped = Array(remotes[index...])
                return outcome
            case let error?:
                outcome.failed.append((remote, error.localizedDescription))
            }
        }
        return outcome
    }

    /// What to say when a new tag did not reach every remote; `nil` when it
    /// did, or when the user cancelled before any went wrong.
    static func newTagPushFailureMessage(tag: String, _ outcome: NewTagPushOutcome) -> String? {
        guard !outcome.failed.isEmpty || (!outcome.skipped.isEmpty && !outcome.pushed.isEmpty) else { return nil }
        var parts = ["The tag “\(tag)” was made here."]
        if !outcome.pushed.isEmpty {
            parts.append("It was pushed to \(quotedList(outcome.pushed)).")
        }
        for failure in outcome.failed {
            parts.append("It wasn’t pushed to “\(failure.remote)”: \(failure.reason)")
        }
        if !outcome.skipped.isEmpty {
            parts.append("Pushing was cancelled before \(quotedList(outcome.skipped)).")
        }
        parts.append("Push it again from the tag’s menu.")
        return parts.joined(separator: "\n\n")
    }

    /// For undoing a tag that was pushed as it was made: says that the
    /// remotes keep it, since Undo only deletes it here. `nil` for any
    /// other record, or a tag that has moved since.
    func pushedTagUndoWarning(_ record: UndoRecord) -> String? {
        guard record.operation.kind == .createTag else { return nil }
        for (name, change) in record.refs where name.hasPrefix("refs/tags/") && change.before == nil {
            guard let after = change.after, let pushed = remotes.pushedNewTags[name], pushed.target == after else {
                continue
            }
            return Self.pushedTagUndoMessage(tag: Self.displayName(ofReference: name), remotes: pushed.remotes)
        }
        return nil
    }

    static func pushedTagUndoMessage(tag: String, remotes: [String]) -> String {
        "“\(tag)” was pushed to \(quotedList(remotes)). Undo deletes it only here; "
            + "\(remotes.count == 1 ? "the remote keeps" : "the remotes keep") it. "
            + "To remove it there too, use Delete “\(tag)” from Remote in the tag’s menu."
    }

    private static func quotedList(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }
        guard quoted.count > 1 else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!
    }
}
