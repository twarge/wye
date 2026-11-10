import Foundation
import GitKit

/// What the composer held before it switched to amending, given back when
/// it switches back.
struct AmendDraft {
    var subject: String
    var details: String
}

extension WorkingCopyState {
    var isAmending: Bool { amend != nil }

    /// Whether the composer's button can go ahead. An amend needs no staged
    /// changes: it can change the message alone.
    var canCommitOrAmend: Bool {
        guard isAmending else { return canCommit }
        return identity != nil && !subject.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var conflictedEntries: [StatusEntry] {
        entries.filter(\.isConflicted)
    }

    var hasUnstagedChanges: Bool {
        entries.contains { $0.unstaged != nil && !$0.isConflicted }
    }
}

extension RepositoryModel {
    // MARK: Lines and hunks

    func stage(lines: Set<Int>, of file: FileDiff) async {
        await perform { try await $0.stage(lines: lines, of: file) }
    }

    func unstage(lines: Set<Int>, of file: FileDiff) async {
        await perform { try await $0.unstage(lines: lines, of: file) }
    }

    func discard(lines: Set<Int>, of file: FileDiff) async {
        await perform { try await $0.discard(lines: lines, of: file) }
    }

    // MARK: Discarding

    func discardChanges(in paths: [String]) async {
        await perform { try await $0.discardChanges(in: paths) }
    }

    func discardAllChanges() async {
        await perform { try await $0.discardAllChanges() }
    }

    // MARK: Amending

    /// Whether there is a commit the composer can amend.
    var canAmend: Bool {
        snapshot?.head.target != nil && (snapshot?.state ?? .clean) == .clean
    }

    /// Switches the composer to amending, loading the last commit's message,
    /// or back, restoring what was being written before.
    func setAmending(_ isAmending: Bool) async {
        if isAmending {
            guard !workingCopy.isAmending else { return }
            do {
                let message = try await repository.lastCommitMessage() ?? ""
                workingCopy.amend = AmendDraft(subject: workingCopy.subject, details: workingCopy.details)
                (workingCopy.subject, workingCopy.details) = Self.split(message)
            } catch {
                self.error = PresentedError(error)
            }
        } else if let draft = workingCopy.amend {
            workingCopy.amend = nil
            workingCopy.subject = draft.subject
            workingCopy.details = draft.details
        }
    }

    /// Commits, or amends the last commit while the composer is amending.
    func commitOrAmend() async {
        guard let draft = workingCopy.amend else {
            await commit()
            return
        }
        let message = composedMessage
        do {
            try await repository.amend(message: message)
            workingCopy.amend = nil
            workingCopy.subject = draft.subject
            workingCopy.details = draft.details
        } catch {
            self.error = PresentedError(error)
        }
        await refresh()
    }

    private var composedMessage: String {
        [workingCopy.subject, workingCopy.details]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// A message as the composer's two fields: the first paragraph, on one
    /// line, and the rest.
    private static func split(_ message: String) -> (subject: String, details: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)
        let subject = parts.first.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") } ?? ""
        let details = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (subject, details)
    }

    // MARK: Stashes

    func saveStash(message: String, options: StashOptions) async {
        await perform { try await $0.saveStash(message: message, options: options) }
    }

    func apply(_ stash: Stash) async {
        await perform { try await $0.applyStash(stash) }
    }

    func pop(_ stash: Stash) async {
        await perform { try await $0.popStash(stash) }
        clearStashSelection(ifGone: stash)
    }

    func drop(_ stash: Stash) async {
        await perform { try await $0.dropStash(stash) }
        clearStashSelection(ifGone: stash)
    }

    private func clearStashSelection(ifGone stash: Stash) {
        if selectedStash == stash.id, snapshot?.stashes.contains(where: { $0.id == stash.id }) != true {
            selectedStash = nil
        }
    }

    // MARK: Conflicts

    func resolveConflict(at path: String, using side: ConflictSide) async {
        await perform { try await $0.resolveConflict(at: path, using: side) }
    }

    func markResolved(_ path: String) async {
        await perform { try await $0.markResolved([path]) }
    }
}
