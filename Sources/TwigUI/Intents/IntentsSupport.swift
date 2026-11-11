import AppIntents
import CoreSpotlight
import Foundation
import Observation

/// Lets an app that links TwigUI take in its intents' metadata.
public struct TwigUIIntentsPackage: AppIntentsPackage {}

/// Keeps what Siri and Spotlight know about the repository list current.
@MainActor
public enum IntentsSupport {
    private static var isStarted = false
    private static var lastNames: [String] = []

    private static var listChanged: @MainActor () -> Void = {}

    /// Starts following the repository list. Call once, when the app
    /// starts, with what tells Siri the names anew: the app's
    /// `AppShortcutsProvider.updateAppShortcutParameters()`, which has to
    /// live in the app target for its phrases to be found.
    public static func start(whenListChanges listChanged: @escaping @MainActor () -> Void) {
        guard !isStarted else { return }
        isStarted = true
        self.listChanged = listChanged
        follow()
    }

    private static func follow() {
        let library = RepositoryLibrary.shared
        let names = withObservationTracking {
            library.listedBookmarks.map { "\($0.id) \($0.name)" }
        } onChange: {
            Task { @MainActor in follow() }
        }
        guard names != lastNames else { return }
        lastNames = names
        let entities = library.listedBookmarks.map { RepositoryEntity($0, in: library) }
        listChanged()
        Task {
            try? await CSSearchableIndex.default().deleteAppEntities(ofType: RepositoryEntity.self)
            try? await CSSearchableIndex.default().indexAppEntities(entities)
        }
    }
}
