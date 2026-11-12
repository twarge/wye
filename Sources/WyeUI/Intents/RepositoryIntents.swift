import AppIntents
import Foundation
import SwiftUI

// The intents run in the app's process without bringing it forward, except
// Open Repository. None of them asks for credentials: an operation that
// would need a prompt fails with a sentence saying to open Wye.

public struct PullRepositoryIntent: AppIntent {
    public static var title: LocalizedStringResource { "Pull Repository" }
    public static var description: IntentDescription {
        IntentDescription("Pulls the current branch of a repository in Wye from its upstream branch.")
    }

    @Parameter(title: "Repository")
    public var repository: RepositoryEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Pull \(\.$repository)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await RepositoryIntentRunner.pull(repository.id)
        return .result(value: message, dialog: "\(message)")
    }
}

public struct FetchRepositoryIntent: AppIntent {
    public static var title: LocalizedStringResource { "Fetch Repository" }
    public static var description: IntentDescription {
        IntentDescription("Fetches every remote of a repository in Wye, without changing its branches.")
    }

    @Parameter(title: "Repository")
    public var repository: RepositoryEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Fetch \(\.$repository)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await RepositoryIntentRunner.fetch(repository.id)
        return .result(value: message, dialog: "\(message)")
    }
}

public struct PushRepositoryIntent: AppIntent {
    public static var title: LocalizedStringResource { "Push Repository" }
    public static var description: IntentDescription {
        IntentDescription(
            "Pushes the current branch of a repository in Wye to its upstream branch, publishing it if it has none. Never forces."
        )
    }

    @Parameter(title: "Repository")
    public var repository: RepositoryEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Push \(\.$repository)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await RepositoryIntentRunner.push(repository.id)
        return .result(value: message, dialog: "\(message)")
    }
}

public struct GetRepositoryStatusIntent: AppIntent {
    public static var title: LocalizedStringResource { "Get Repository Status" }
    public static var description: IntentDescription {
        IntentDescription(
            "Tells the branch a repository in Wye is on, how far it is ahead of and behind its upstream, and how many files have changes. Does not fetch."
        )
    }

    @Parameter(title: "Repository")
    public var repository: RepositoryEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Get the status of \(\.$repository)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<RepositoryStatusEntity> & ProvidesDialog & ShowsSnippetView {
        let status = try await RepositoryIntentRunner.status(repository.id)
        return .result(
            value: status, dialog: "\(status.summary)",
            view: RepositoryStatusSnippet(
                name: status.name, branch: status.branch, ahead: status.ahead, behind: status.behind,
                changedFiles: status.changedFiles
            )
        )
    }
}

public struct FetchAllRepositoriesIntent: AppIntent {
    public static var title: LocalizedStringResource { "Fetch All Repositories" }
    public static var description: IntentDescription {
        IntentDescription("Fetches every repository in Wye’s list that has a remote.")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = await RepositoryIntentRunner.fetchAll()
        return .result(value: message, dialog: "\(message)")
    }
}

public struct OpenRepositoryIntent: OpenIntent {
    public static var title: LocalizedStringResource { "Open Repository" }
    public static var description: IntentDescription {
        IntentDescription("Opens a repository in Wye.")
    }

    @Parameter(title: "Repository")
    public var target: RepositoryEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        _ = try RepositoryIntentRunner.bookmark(for: target.id)
        LinkRouter.shared.request(.openRepository(target.id))
        return .result()
    }
}
