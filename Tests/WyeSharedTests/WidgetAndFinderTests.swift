import Foundation
import Testing
@testable import WyeShared

// In the suite that already points the shared container at a temporary
// folder, so the tests that do take turns.
extension PendingCloneTests {
    @Test func widgetRequestsWaitForTheAppOnce() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WyeSharedTests-\(UUID().uuidString)")
        SharedContainer.directoryOverride = folder
        defer {
            SharedContainer.directoryOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let id = UUID()
        #expect(WidgetActions.take().isEmpty)
        WidgetActions.leave(.fetchAll)
        WidgetActions.leave(.pull(id))
        // Asking twice is one request.
        WidgetActions.leave(.fetchAll)
        #expect(WidgetActions.take() == [.pull(id), .fetchAll])
        #expect(WidgetActions.take().isEmpty)
    }

    @Test func widgetRequestsLeftLongAgoAreDropped() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WyeSharedTests-\(UUID().uuidString)")
        SharedContainer.directoryOverride = folder
        defer {
            SharedContainer.directoryOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let now = Date.now
        WidgetActions.leave(.fetchAll, now: now.addingTimeInterval(-WidgetActions.lifetime - 60))
        WidgetActions.leave(.fetch(UUID()), now: now)
        let taken = WidgetActions.take(now: now)
        #expect(taken.count == 1)
        #expect(taken.first != .fetchAll)
    }

    @Test func finderStatusRoundTripsAndForgetsRemovedRepositories() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WyeSharedTests-\(UUID().uuidString)")
        SharedContainer.directoryOverride = folder
        defer {
            SharedContainer.directoryOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let kept = FinderRepositoryStatus(id: UUID(), name: "kept", root: "/r/kept/", branch: "main", badges: ["a.txt": .modified])
        let gone = FinderRepositoryStatus(id: UUID(), name: "gone", root: "/r/gone", branch: nil, badges: [:])
        FinderStatusStore.save(kept)
        FinderStatusStore.save(gone)
        #expect(Set(FinderStatusStore.loadAll()) == [kept, gone])
        FinderStatusStore.retain([kept.id])
        #expect(FinderStatusStore.loadAll() == [kept])
        // A trailing slash on the root is dropped, so paths compare.
        #expect(kept.root == "/r/kept")
    }
}

@Suite struct FinderBadgeIndexTests {
    private func repository(_ root: String, _ badges: [String: FinderBadge]) -> FinderRepositoryStatus {
        FinderRepositoryStatus(id: UUID(), name: "r", root: root, branch: "main", badges: badges)
    }

    @Test func badgesFilesAndTheFoldersAboveThem() {
        let index = FinderBadgeIndex([repository("/r/app", ["Sources/UI/View.swift": .modified, "notes.txt": .untracked])])
        #expect(index.badge(forPath: "/r/app/Sources/UI/View.swift") == .modified)
        #expect(index.badge(forPath: "/r/app/Sources/UI") == .modified)
        #expect(index.badge(forPath: "/r/app/Sources/") == .modified)
        #expect(index.badge(forPath: "/r/app") == .modified)
        #expect(index.badge(forPath: "/r/app/notes.txt") == .untracked)
        #expect(index.badge(forPath: "/r/app/README.md") == nil)
        #expect(index.badge(forPath: "/r") == nil)
    }

    @Test func aFolderShowsWhatMostWantsAttention() {
        let index = FinderBadgeIndex([repository("/r/app", ["a/one": .staged, "a/two": .conflicted, "b/three": .staged])])
        #expect(index.badge(forPath: "/r/app/a") == .conflicted)
        #expect(index.badge(forPath: "/r/app") == .conflicted)
        // A folder holding only staged or new files is simply changed.
        #expect(index.badge(forPath: "/r/app/b") == .modified)
        #expect(index.badge(forPath: "/r/app/b/three") == .staged)
    }

    @Test func findsTheInnermostRepositoryOfAPath() {
        let outer = repository("/r/app", [:])
        let inner = repository("/r/app/Vendor/lib", [:])
        let index = FinderBadgeIndex([outer, inner])
        #expect(index.repository(containing: "/r/app/Vendor/lib/src/x.c")?.id == inner.id)
        #expect(index.repository(containing: "/r/app/Vendor")?.id == outer.id)
        #expect(index.repository(containing: "/r/app")?.id == outer.id)
        // A sibling whose name only starts the same is not inside.
        #expect(index.repository(containing: "/r/application/x") == nil)
    }
}
