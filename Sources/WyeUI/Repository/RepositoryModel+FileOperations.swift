import Foundation
import GitKit
import Observation

/// A file action waiting for the user: a confirmation, or a new name.
enum FileRequest: Identifiable, Hashable {
    /// Move an untracked file to the Trash, or delete it where there is none.
    case trash(path: String)
    /// Ask for a new path, then move the file there.
    case rename(path: String)
    /// Take files out of the index, keeping them on disk.
    case stopTracking(paths: [String], afterIgnoring: Bool)
    /// Overwrite a file that has local changes with its version at a commit.
    case restore(path: String, commit: OID)

    var id: Self { self }
}

/// The file actions waiting on the user, for whichever view is showing.
/// Commit detail and the working copy both ask; the repository window
/// answers, so the dialogs show wherever the request came from.
@MainActor
@Observable
final class FileRequests {
    var pending: FileRequest?
    /// The file Quick Look is showing.
    var quickLook: URL?
}

extension RepositoryModel {
    /// Where a path of the working tree is on disk.
    func fileURL(for path: String) -> URL {
        repository.url.appending(path: path)
    }

    /// Whether the path names something on disk, to offer opening it.
    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: path).path)
    }

    // MARK: Moving and removing

    func moveFile(_ path: String, to newPath: String) async {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != path else { return }
        await perform { try await $0.move(path, to: trimmed) }
        if workingCopy.selection == path {
            workingCopy.selection = workingCopy.entries.contains { $0.path == trimmed } ? trimmed : nil
        }
    }

    /// Removes an untracked file, to the Trash where there is one.
    func trashUntrackedFile(_ path: String) async {
        await perform { try await $0.discardChanges(in: [path], untracked: .trash) }
    }

    // MARK: Ignoring and tracking

    /// Adds an ignore rule, then offers to stop tracking the tracked files
    /// it matches, which git would otherwise go on showing. Returns those
    /// files, for a caller that makes the offer itself.
    @discardableResult
    func ignore(_ pattern: String, in file: IgnoreFile, offeringToStopTracking: Bool = true) async -> [String] {
        var newlyIgnored: [String] = []
        await perform { repository in
            let before = try await repository.trackedIgnoredPaths()
            try await repository.addIgnorePatterns([pattern], to: file)
            let after = try await repository.trackedIgnoredPaths()
            newlyIgnored = after.subtracting(before).sorted()
        }
        if offeringToStopTracking, !newlyIgnored.isEmpty {
            fileRequests.pending = .stopTracking(paths: newlyIgnored, afterIgnoring: true)
        }
        return newlyIgnored
    }

    func stopTracking(_ paths: [String]) async {
        await perform { try await $0.stopTracking(paths) }
    }

    func setAssumeUnchanged(_ isAssumed: Bool, for paths: [String]) async {
        await perform { try await $0.setAssumeUnchanged(isAssumed, for: paths) }
    }

    // MARK: Restoring

    /// Puts a file's version at a commit into the working tree, asking
    /// first when that would overwrite changes not yet committed.
    func requestRestore(_ path: String, from commit: OID) async {
        do {
            if try await repository.hasUncommittedChanges(at: path) {
                fileRequests.pending = .restore(path: path, commit: commit)
                return
            }
        } catch {
            report(error)
            return
        }
        await restore(path, from: commit)
    }

    func restore(_ path: String, from commit: OID) async {
        await perform { try await $0.restore(path, from: commit) }
    }

    // MARK: Composing

    /// Recent messages on this branch, for the composer to start from.
    func recentCommitMessages() async -> [String] {
        do {
            return try await repository.recentCommitMessages()
        } catch {
            report(error)
            return []
        }
    }

    /// The repository's own `commit.template`, when it has one Wye can read.
    func repositoryCommitTemplate() async -> String? {
        try? await repository.commitTemplate()
    }

    /// Puts a message in the composer, as subject and description.
    func useMessage(_ message: String, isTemplate: Bool) {
        (workingCopy.subject, workingCopy.details) = CommitMessageText.split(message, strippingComments: isTemplate)
    }
}
