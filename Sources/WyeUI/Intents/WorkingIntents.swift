import AppIntents
import Foundation
import GitKit
import SwiftUI

// Intents that change a repository's own state rather than talk to a
// remote: commit, check out, stash. Like the others they run without
// bringing Wye forward and without asking anything.

public struct CommitChangesIntent: AppIntent {
    public static var title: LocalizedStringResource { "Commit Changes" }
    public static var description: IntentDescription {
        IntentDescription(
            "Commits a repository’s changes in Wye with a message. Stages every change first unless told to commit only what is already staged. The commit is not signed."
        )
    }

    @Parameter(title: "Repository")
    public var repository: RepositoryEntity

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    public var message: String

    @Parameter(title: "Stage All Changes", default: true)
    public var stagesAll: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Commit changes in \(\.$repository) with \(\.$message)") {
            \.$stagesAll
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await RepositoryIntentRunner.commit(repository.id, message: message, stagingAll: stagesAll)
        return .result(value: text, dialog: "\(text)")
    }
}

public struct CheckOutBranchIntent: AppIntent {
    public static var title: LocalizedStringResource { "Check Out Branch" }
    public static var description: IntentDescription {
        IntentDescription(
            "Checks out a branch of a repository in Wye. A branch that is only on a remote is checked out as a local branch that tracks it."
        )
    }

    @Parameter(title: "Repository")
    public var repository: RepositoryEntity

    @Parameter(title: "Branch", optionsProvider: BranchOptions())
    public var branch: String

    public static var parameterSummary: some ParameterSummary {
        Summary("Check out \(\.$branch) in \(\.$repository)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await RepositoryIntentRunner.checkOut(repository.id, branch: branch)
        return .result(value: text, dialog: "\(text)")
    }

    /// The chosen repository's branches, local ones first.
    public struct BranchOptions: DynamicOptionsProvider {
        @IntentParameterDependency<CheckOutBranchIntent>(\.$repository) var intent

        public init() {}

        @MainActor
        public func results() async throws -> [String] {
            guard let id = intent?.repository.id else { return [] }
            return try await RepositoryIntentRunner.branchNames(id)
        }
    }
}

public struct StashChangesIntent: AppIntent {
    public static var title: LocalizedStringResource { "Stash Changes" }
    public static var description: IntentDescription {
        IntentDescription("Sets a repository’s uncommitted changes aside in a stash, untracked files included.")
    }

    @Parameter(title: "Repository")
    public var repository: RepositoryEntity

    @Parameter(title: "Message")
    public var message: String?

    public static var parameterSummary: some ParameterSummary {
        Summary("Stash changes in \(\.$repository)") {
            \.$message
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await RepositoryIntentRunner.stash(repository.id, message: message)
        return .result(value: text, dialog: "\(text)")
    }
}

public struct PullAllRepositoriesIntent: AppIntent {
    public static var title: LocalizedStringResource { "Pull All Repositories" }
    public static var description: IntentDescription {
        IntentDescription("Pulls every repository in Wye’s list that has an upstream, and says which could not be pulled.")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await RepositoryIntentRunner.pullAll()
        return .result(value: text, dialog: "\(text)")
    }
}

public struct FindUnpushedRepositoriesIntent: AppIntent {
    public static var title: LocalizedStringResource { "Find Repositories with Unpushed Work" }
    public static var description: IntentDescription {
        IntentDescription(
            "Lists the repositories in Wye with commits not pushed or changes not committed, as of when Wye last read them. Does not fetch."
        )
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[RepositoryEntity]> & ProvidesDialog {
        let found = RepositoryIntentRunner.unpushed()
        let dialog: String = switch found.count {
        case 0: "Everything is committed and pushed."
        case 1: "\(found[0].name) has work that is not pushed."
        default: "\(found.count) repositories have work that is not pushed: " + found.map(\.name).formatted(.list(type: .and)) + "."
        }
        return .result(value: found, dialog: "\(dialog)")
    }
}

public struct CloneRepositoryIntent: AppIntent {
    public static var title: LocalizedStringResource { "Clone Repository" }
    public static var description: IntentDescription {
        IntentDescription("Opens Wye’s clone sheet with an address filled in, to choose where the clone goes.")
    }
    public static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Address")
    public var address: String

    public static var parameterSummary: some ParameterSummary {
        Summary("Clone \(\.$address)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntentFailure(message: "There is no address to clone.") }
        LinkRouter.shared.request(.clone(trimmed))
        return .result()
    }
}

/// A repository's status as Siri, Spotlight and Shortcuts show it beside
/// the sentence: the branch and the counts, at a glance.
struct RepositoryStatusSnippet: View {
    var name: String
    var branch: String?
    var ahead: Int
    var behind: Int
    var changedFiles: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                Label(branch ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                if behind > 0 { Label("\(behind)", systemImage: "arrow.down") }
                if ahead > 0 { Label("\(ahead)", systemImage: "arrow.up") }
                if changedFiles > 0 { Label("\(changedFiles)", systemImage: "pencil") }
                if behind == 0, ahead == 0, changedFiles == 0 {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

extension RepositoryIntentRunner {
    static func commit(_ id: UUID, message: String, stagingAll: Bool) async throws -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw IntentFailure(message: "A commit needs a message.") }
        return try await run("Committing", on: id) { repository, bookmark in
            var entries = try await repository.status()
            if entries.contains(where: \.isConflicted) {
                throw IntentFailure(message: "\(bookmark.name) has conflicts. Open Wye to resolve them first.")
            }
            if stagingAll {
                let unstaged = entries.filter { $0.unstaged != nil }.map(\.path)
                if !unstaged.isEmpty {
                    try await repository.stage(unstaged)
                    entries = try await repository.status()
                }
            }
            let staged = entries.count { $0.staged != nil }
            guard staged > 0 else {
                throw IntentFailure(message: stagingAll
                    ? "\(bookmark.name) has no changes to commit."
                    : "\(bookmark.name) has nothing staged to commit.")
            }
            let commit = try await repository.commit(message: message)
            return "Committed \(IntentPhrasing.files(staged)) in \(bookmark.name) as \(commit.abbreviated())."
        }
    }

    static func branchNames(_ id: UUID) async throws -> [String] {
        try await run("Reading", on: id) { repository, _ in
            let snapshot = try await repository.snapshot()
            let local = snapshot.branches.map(\.name)
            let remote = snapshot.remotes.flatMap(\.branches).map(\.name)
                .filter { !$0.hasSuffix("/HEAD") }
            return local + remote
        }
    }

    static func checkOut(_ id: UUID, branch: String) async throws -> String {
        let wanted = branch.trimmingCharacters(in: .whitespaces)
        return try await run("Checking out", on: id) { repository, bookmark in
            let snapshot = try await repository.snapshot()
            if let local = snapshot.branches.first(where: { $0.name == wanted }) {
                if local.isHead { return "\(bookmark.name) is already on \(wanted)." }
                try await repository.checkOut(branch: local.id)
                return "Checked out \(wanted) in \(bookmark.name)."
            }
            // A remote branch by its full name, `origin/topic`, or by the
            // name it would have here, when only one remote has it.
            let remotes = snapshot.remotes.flatMap(\.branches)
            let matches = remotes.filter { $0.name == wanted || $0.nameWithoutRemote == wanted }
            guard let remote = matches.first, matches.count == 1 || remote.name == wanted else {
                throw IntentFailure(message: matches.isEmpty
                    ? "\(bookmark.name) has no branch called \(wanted)."
                    : "More than one remote of \(bookmark.name) has a branch called \(wanted). Say which, as in origin/\(wanted).")
            }
            // One already made for it is checked out rather than made again.
            if let local = snapshot.branches.first(where: { $0.name == remote.nameWithoutRemote }) {
                try await repository.checkOut(branch: local.id)
                return "Checked out \(local.name) in \(bookmark.name)."
            }
            let created = try await repository.createTrackingBranch(for: remote.id)
            try await repository.checkOut(branch: created)
            return "Checked out \(remote.nameWithoutRemote) in \(bookmark.name), tracking \(remote.name)."
        }
    }

    static func stash(_ id: UUID, message: String?) async throws -> String {
        try await run("Stashing", on: id) { repository, bookmark in
            let count = try await repository.status().count
            guard count > 0 else { return "\(bookmark.name) has no changes to stash." }
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await repository.saveStash(
                message: trimmed?.isEmpty == false ? trimmed : nil, options: [.includeUntracked]
            )
            return "Stashed the changes to \(IntentPhrasing.files(count)) in \(bookmark.name)."
        }
    }

    /// Pulls every listed repository, one after another, as Pull All does.
    static func pullAll() async -> String {
        var results: [PullAllResult] = []
        for bookmark in RepositoryLibrary.shared.listedBookmarks {
            let outcome: PullAllResult.Outcome
            do {
                outcome = try await pullQuietly(bookmark.id)
            } catch let failure as IntentFailure {
                outcome = .failed(failure.message)
            } catch {
                outcome = .failed(IntentPhrasing.failure(error, name: bookmark.name))
            }
            results.append(PullAllResult(id: bookmark.id, name: bookmark.name, outcome: outcome))
        }
        return IntentPhrasing.pulledAll(results)
    }

    /// The listed repositories with unpushed work, by what Wye last read.
    static func unpushed() -> [RepositoryEntity] {
        let library = RepositoryLibrary.shared
        let summaries = RepositoryStatusBoard.shared.summaries
        return library.listedBookmarks
            .filter { summaries[$0.id]?.hasUnpushedWork == true }
            .map { RepositoryEntity($0, in: library) }
    }
}

extension IntentPhrasing {
    /// Pull All as one thing to say: the counts, then the first that went wrong.
    static func pulledAll(_ results: [PullAllResult]) -> String {
        guard !results.isEmpty else { return "There are no repositories in Wye to pull." }
        var text = PullAllReport.summary(of: results).capitalizedFirst + "."
        let problems = results.filter(\.isProblem)
        if let first = problems.first, case .failed(let detail) = first.outcome {
            text += " \(first.name): \(detail)"
        } else if let first = problems.first, case .needsAttention(let detail) = first.outcome {
            text += " \(first.name): \(detail)"
        }
        if problems.count > 1 {
            text += " \(problems.count - 1) more need a look in Wye."
        }
        return text
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
