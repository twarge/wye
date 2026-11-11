import Foundation
import GitKit
import Testing
import WyeShared
@testable import WyeUI

@Suite struct NavigationHistoryTests {
    @Test func goesBackAndForward() {
        var history = NavigationHistory<Int>(capacity: 10)
        #expect(!history.canGoBack && !history.canGoForward)
        history.visit(1)
        history.visit(2)
        history.visit(3)
        #expect(history.goBack() == 2)
        #expect(history.goBack() == 1)
        #expect(history.goBack() == nil)
        #expect(history.current == 1)
        #expect(history.goForward() == 2)
        #expect(history.current == 2)
        #expect(history.canGoBack && history.canGoForward)
    }

    @Test func aNewVisitDropsTheWayForward() {
        var history = NavigationHistory<Int>()
        history.visit(1)
        history.visit(2)
        _ = history.goBack()
        history.visit(5)
        #expect(!history.canGoForward)
        #expect(history.goBack() == 1)
    }

    @Test func ignoresVisitsToTheSamePlace() {
        var history = NavigationHistory<Int>()
        history.visit(1)
        history.visit(1)
        #expect(!history.canGoBack)
    }

    @Test func keepsOnlyTheMostRecentPlaces() {
        var history = NavigationHistory<Int>(capacity: 3)
        for place in 1...10 { history.visit(place) }
        #expect(history.backStack == [7, 8, 9])
        #expect(history.goBack() == 9)
        #expect(history.goBack() == 8)
        #expect(history.goBack() == 7)
        #expect(history.goBack() == nil)
    }

    @Test func aDetailChosenRefinesThePlaceRatherThanAddingOne() {
        var history = NavigationHistory<RepositoryLocation>()
        let commit = OID(hex: String(repeating: "a", count: 40))!
        let refines: (RepositoryLocation, RepositoryLocation) -> Bool = { $0.isRefined(by: $1) }
        history.visit(RepositoryLocation(sidebar: .workingCopy, file: "a.txt"), refines: refines)
        history.visit(RepositoryLocation(sidebar: .history), refines: refines)
        history.visit(RepositoryLocation(sidebar: .history, commit: commit), refines: refines)
        #expect(history.backStack == [RepositoryLocation(sidebar: .workingCopy, file: "a.txt")])
        #expect(history.goBack() == RepositoryLocation(sidebar: .workingCopy, file: "a.txt"))
        #expect(history.goForward() == RepositoryLocation(sidebar: .history, commit: commit))
    }
}

@MainActor
@Suite struct ActivityLogTests {
    @Test func listsMostRecentFirstAndRecordsOutcomes() {
        let log = ActivityLog(capacity: 10)
        let start = Date(timeIntervalSince1970: 1000)
        let fetch = log.begin("Fetch", repository: "one", at: start)
        let push = log.begin("Push", repository: "two", at: start.addingTimeInterval(1))
        #expect(log.entries.map(\.title) == ["Push", "Fetch"])
        log.finish(fetch, .succeeded, transfer: TransferProgress(phase: .receivingObjects, completed: 3, total: 3, bytes: 100),
                   at: start.addingTimeInterval(2.5))
        log.finish(push, error: RemoteError.noRemotes)
        #expect(log.entries[1].duration == 2.5)
        #expect(log.entries[1].transfer?.bytes == 100)
        #expect(log.entries[0].failure == RemoteError.noRemotes.localizedDescription)
        log.finish(log.begin("Pull", repository: nil), error: CancellationError())
        #expect(log.entries[0].outcome == .cancelled)
    }

    @Test func dropsTheOldestFinishedEntriesWhenFull() {
        let log = ActivityLog(capacity: 3)
        let running = log.begin("Clone", repository: nil)
        for index in 1...5 {
            log.finish(log.begin("Op \(index)", repository: "r"), .succeeded)
        }
        #expect(log.entries.count == 3)
        // The operation still under way stays, however old.
        #expect(log.entries.map(\.title) == ["Op 5", "Op 4", "Clone"])
        log.clear()
        #expect(log.entries.map(\.id) == [running])
    }

    @Test func namesProgressTitlesAsThingsDone() {
        #expect(ActivityLog.title(forProgress: "Fetching “origin”") == "Fetch “origin”")
        #expect(ActivityLog.title(forProgress: "Force Pushing") == "Force Push")
        #expect(ActivityLog.title(forProgress: "Pulling") == "Pull")
        #expect(ActivityLog.title(forProgress: "Commit") == "Commit")
    }
}

@Suite struct BackgroundFetchPolicyTests {
    let now = Date(timeIntervalSince1970: 100_000)
    let interval: TimeInterval = 15 * 60

    private func decide(
        _ record: BackgroundFetchRecord = .init(), interval: TimeInterval?? = nil, isBusy: Bool = false,
        network: NetworkCondition = .unmetered, allowsExpensive: Bool = false
    ) -> BackgroundFetchPolicy.Decision {
        BackgroundFetchPolicy.decide(
            record: record, interval: interval ?? self.interval, now: now, isBusy: isBusy, hasRemote: true,
            network: network, allowsExpensiveNetworks: allowsExpensive
        )
    }

    @Test func fetchesARepositoryNeverTried() {
        #expect(decide() == .fetch)
    }

    @Test func waitsForTheInterval() {
        let record = BackgroundFetchRecord(lastAttempt: now.addingTimeInterval(-60))
        #expect(decide(record) == .wait(until: now.addingTimeInterval(interval - 60)))
        #expect(decide(BackgroundFetchRecord(lastAttempt: now.addingTimeInterval(-interval))) == .fetch)
    }

    @Test func skipsWhenOffBusyOrOnTheWrongNetwork() {
        #expect(decide(interval: .some(nil)) == .skip(.disabled))
        #expect(decide(isBusy: true) == .skip(.busy))
        #expect(decide(network: .unavailable) == .skip(.offline))
        #expect(decide(network: .expensive) == .skip(.expensiveNetwork))
        #expect(decide(network: .expensive, allowsExpensive: true) == .fetch)
    }

    @Test func backsOffAfterFailures() {
        var record = BackgroundFetchRecord()
        for _ in 0..<3 {
            record = BackgroundFetchPolicy.record(after: RemoteError.noRemotes, at: now, previous: record)
        }
        #expect(record.consecutiveFailures == 3)
        #expect(BackgroundFetchPolicy.nextAttempt(after: record, interval: interval) == now.addingTimeInterval(interval * 8))
        for _ in 0..<20 {
            record = BackgroundFetchPolicy.record(after: RemoteError.noRemotes, at: now, previous: record)
        }
        #expect(BackgroundFetchPolicy.nextAttempt(after: record, interval: interval)
                == now.addingTimeInterval(BackgroundFetchPolicy.maximumBackoff))
        // One success starts again from the interval.
        record = BackgroundFetchPolicy.record(after: nil, at: now, previous: record)
        #expect(record == BackgroundFetchRecord(lastAttempt: now))
    }

    @Test func leavesRemotesThatWantCredentialsAloneForADay() {
        let record = BackgroundFetchPolicy.record(
            after: RemoteError.credentialsRequired(host: "example.com", username: nil), at: now, previous: .init()
        )
        #expect(record.needsCredentials)
        #expect(BackgroundFetchPolicy.nextAttempt(after: record, interval: interval)
                == now.addingTimeInterval(BackgroundFetchPolicy.credentialsBackoff))
        #expect(!BackgroundFetchPolicy.wantsCredentials(RemoteError.noRemotes))
    }

    @Test func countsNewCommitsOnlyWhenTheUpstreamMoved() {
        let a = OID(hex: String(repeating: "a", count: 40))!
        let b = OID(hex: String(repeating: "b", count: 40))!
        #expect(BackgroundFetchPolicy.newCommits(upstreamBefore: a, upstreamAfter: a, behindBefore: 2, behindAfter: 2) == 0)
        #expect(BackgroundFetchPolicy.newCommits(upstreamBefore: a, upstreamAfter: b, behindBefore: 2, behindAfter: 5) == 3)
        #expect(BackgroundFetchPolicy.newCommits(upstreamBefore: nil, upstreamAfter: b, behindBefore: 0, behindAfter: 4) == 4)
        // A force-pushed upstream with nothing new to pull.
        #expect(BackgroundFetchPolicy.newCommits(upstreamBefore: a, upstreamAfter: b, behindBefore: 0, behindAfter: 0) == 0)
    }
}

@Suite struct RepositorySettingsLogicTests {
    @Test func editsOneValueOfAMultiValuedKey() {
        let values = ["a", "b", "c"]
        #expect(ConfigurationEdit.values(values, replacingAt: 1, with: "B") == ["a", "B", "c"])
        #expect(ConfigurationEdit.values(values, replacingAt: 0, with: nil) == ["b", "c"])
        #expect(ConfigurationEdit.values(values, replacingAt: 5, with: "x") == values)
    }

    @Test func numbersTheValuesOfEachKey() {
        let entries = [
            ConfigurationEntry(name: "remote.origin.fetch", value: "one"),
            ConfigurationEntry(name: "core.bare", value: "false"),
            ConfigurationEntry(name: "remote.origin.fetch", value: "two")
        ]
        let indexed = ConfigurationEdit.indexed(entries)
        #expect(indexed.map(\.index) == [0, 0, 1])
        #expect(indexed.map(\.count) == [2, 1, 2])
        #expect(Set(indexed.map(\.id)).count == 3)
    }

    @Test func choosesTheRemoteToFetch() throws {
        let suite = "WyeUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let remotes = ["origin", "upstream", "mine"]
        #expect(RepositoryPreferences.remoteToFetch(for: id, remotes: remotes, upstream: nil, defaults: defaults) == "origin")
        #expect(RepositoryPreferences.remoteToFetch(for: id, remotes: remotes, upstream: "upstream/main", defaults: defaults) == "upstream")
        RepositoryPreferences.setDefaultRemote("mine", for: id, defaults: defaults)
        #expect(RepositoryPreferences.remoteToFetch(for: id, remotes: remotes, upstream: "upstream/main", defaults: defaults) == "mine")
        // A chosen remote that has gone is passed over.
        #expect(RepositoryPreferences.remoteToFetch(for: id, remotes: ["a", "b"], upstream: nil, defaults: defaults) == nil)
        RepositoryPreferences.setAutostash(.always, for: id, defaults: defaults)
        #expect(RepositoryPreferences.autostash(for: id, defaults: defaults) == .always)
        RepositoryPreferences.setAutostash(nil, for: id, defaults: defaults)
        #expect(RepositoryPreferences.autostash(for: id, defaults: defaults) == nil)
    }
}

@MainActor
@Suite(.serialized) struct SharedStatusTests {
    @Test func summariesRoundTripThroughTheStore() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WyeUITests-\(UUID().uuidString)")
        defer {
            SharedStatusStore.fileURLOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        SharedStatusStore.fileURLOverride = folder.appending(path: "Status.json")
        #expect(SharedStatusStore.load().isEmpty)
        // Whole seconds: the file keeps dates to the second.
        let summaries = [
            RepositoryStatusSummary(id: UUID(), name: "one", branch: "main", ahead: 2, behind: 0,
                                    hasUncommittedChanges: true, updated: Date(timeIntervalSince1970: 1_700_000_000)),
            RepositoryStatusSummary(id: UUID(), name: "two", branch: nil, ahead: 0, behind: 3,
                                    hasUncommittedChanges: false, updated: Date(timeIntervalSince1970: 1_700_000_100))
        ]
        SharedStatusStore.save(summaries)
        #expect(SharedStatusStore.load() == summaries)
    }

    @Test func theBoardKeepsOnlyListedRepositories() {
        let board = RepositoryStatusBoard(publishes: false)
        let kept = RepositoryStatusSummary(id: UUID(), name: "kept", branch: "main", ahead: 1, behind: 0,
                                           hasUncommittedChanges: false, updated: .now)
        let gone = RepositoryStatusSummary(id: UUID(), name: "gone", branch: "main", ahead: 0, behind: 0,
                                           hasUncommittedChanges: false, updated: .now)
        board.record(kept)
        board.record(gone)
        board.retain([kept.id])
        #expect(board.summaries == [kept.id: kept])
    }
}
