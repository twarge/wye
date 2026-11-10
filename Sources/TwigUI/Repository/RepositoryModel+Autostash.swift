import Foundation
import GitKit
import Observation

/// Something an operation wants the user to know that is not a failure:
/// where their stashed changes went, or why a pull stopped.
struct OperationNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Asks whether to stash local changes that are in an operation's way.
@MainActor
@Observable
final class AutostashBroker {
    /// The question on screen: the operation's name, such as "Pull".
    private(set) var pendingAction: String?

    private var continuation: CheckedContinuation<Bool, Never>?

    func ask(_ action: String) async -> Bool {
        // One question at a time; a second is declined.
        guard continuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            pendingAction = action
        }
    }

    func answer(_ stash: Bool) {
        pendingAction = nil
        continuation?.resume(returning: stash)
        continuation = nil
    }
}

extension RepositoryModel {
    /// Runs an operation that local changes can block, setting them aside
    /// in a stash around it as the Stash Local Changes setting says:
    /// always, never, or after asking once they turn out to be in the way.
    /// Says afterwards where the changes are if they could not simply be
    /// put back.
    func withAutostash<Value: Sendable>(
        _ action: String,
        _ operation: @escaping @Sendable (isolated Repository) throws -> Value
    ) async throws -> Value {
        let policy = RemotePreferences.autostash
        if policy == .always {
            return try await runAutostashed(action, operation)
        }
        do {
            return try await operation(repository)
        } catch let error as GitError where error.isBlockedByLocalChanges && policy == .ask {
            guard try await repository.hasChangesToTrackedFiles(), await remotes.autostash.ask(action) else {
                throw error
            }
            return try await runAutostashed(action, operation)
        }
    }

    private func runAutostashed<Value: Sendable>(
        _ action: String, _ operation: @escaping @Sendable (isolated Repository) throws -> Value
    ) async throws -> Value {
        let result = try await repository.withAutostash(message: "autostash before \(action.lowercased())", operation)
        report(result.autostash, after: action)
        return result.value
    }

    /// Tells the user where stashed changes are when they were not simply
    /// put back.
    func report(_ autostash: AutostashResult, after action: String, stoppedReason: String? = nil) {
        let note: String? = switch autostash {
        case .notNeeded, .restored:
            nil
        case .conflicted(_, let paths):
            "Your local changes were put back, with conflicts in \(Self.describe(paths)). Resolve them in the "
                + "working copy. The changes are also kept in a stash, in case you need them again."
        case .notApplied:
            "Your local changes could not be put back, so they are kept in a stash. Apply it from Stashes "
                + "once the files in its way are gone."
        case .keptForLater:
            "Your local changes are kept in a stash. Once the conflicts are resolved and the "
                + "\(action.lowercased()) is finished, pop the stash from Stashes."
        }
        if case .conflicted = autostash {
            selection = .workingCopy
        }
        let message = [stoppedReason, note].compactMap { $0 }.joined(separator: "\n\n")
        guard !message.isEmpty else { return }
        remotes.notice = OperationNotice(
            title: stoppedReason == nil ? "Local Changes Stashed" : "\(action) Stopped", message: message
        )
    }

    static func describe(_ paths: [String]) -> String {
        paths.count == 1 ? "“\(paths[0])”" : "\(paths.count) files"
    }
}
