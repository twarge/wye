import Foundation
import GitKit
import Testing
@testable import WyeUI

@Suite struct NoticeTests {
    @Test func aFailureIsNamedAfterItsOperation() {
        #expect(NoticeText.failureTitle(for: "Push “main”") == "Couldn’t Push “main”")
        #expect(NoticeText.failureTitle(for: nil) == "That Didn’t Work")
        #expect(NoticeText.failureTitle(for: "Operation") == "That Didn’t Work")
        let notice = Notice(RemoteError.nonFastForward(branch: "main"), during: "Push")
        #expect(notice.kind == .failure)
        #expect(notice.title == "Couldn’t Push")
        #expect(notice.message == RemoteError.nonFastForward(branch: "main").localizedDescription)
    }

    @Test func aFailureOffersWhatWouldFixIt() {
        #expect(NoticeText.recoveries(for: RemoteError.nonFastForward(branch: "main")) == [.pull])
        #expect(NoticeText.recoveries(for: RemoteError.remoteMoved(branch: "main")) == [.fetch])
        #expect(NoticeText.recoveries(for: RemoteError.noRemotes) == [.manageRemotes])
        #expect(NoticeText.recoveries(for: RemoteError.sshKeyRequired(host: "example.com", username: "git")) == [.settings])
        #expect(NoticeText.recoveries(for: RepositoryError.identityNotConfigured) == [.settings])
        #expect(NoticeText.recoveries(for: RepositoryError.nothingToCommit) == [.showWorkingCopy])
        #expect(NoticeText.recoveries(for: RemoteError.notOnBranch).isEmpty)
        #expect(NoticeText.recoveries(for: CocoaError(.fileNoSuchFile)).isEmpty)
    }

    @Test func theSameThingSaidAgainCountsInsteadOfPilingUp() {
        var queue = NoticeQueue()
        queue.post(Notice(.failure, title: "Couldn’t Stage", message: "No such file."))
        queue.post(Notice(.information, title: "Published", message: "Done."))
        queue.post(Notice(.failure, title: "Couldn’t Stage", message: "No such file."))
        #expect(queue.notices.map(\.title) == ["Couldn’t Stage", "Published"])
        #expect(queue.notices.map(\.count) == [2, 1])
    }

    @Test func olderNoticesMakeRoom() {
        var queue = NoticeQueue(capacity: 3)
        for number in 1...5 {
            queue.post(Notice(.failure, title: "Failure \(number)", message: ""))
        }
        #expect(queue.notices.map(\.title) == ["Failure 5", "Failure 4", "Failure 3"])
    }

    @Test func aSuccessTakesTheOperationsFailuresAway() {
        var queue = NoticeQueue()
        queue.post(Notice(RemoteError.noRemotes, during: "Push"))
        queue.post(Notice(RemoteError.noRemotes, during: "Fetch"))
        queue.post(Notice(.information, title: "Published", message: "", operation: "Push"))
        queue.resolve(operation: "Push")
        #expect(queue.notices.map(\.title) == ["Published", "Couldn’t Fetch"])
        let first = queue.notices[0].id
        queue.dismiss(first)
        #expect(queue.notices.count == 1)
        queue.dismissAll()
        #expect(queue.notices.isEmpty)
    }

    @MainActor
    @Test func aCancelledOperationSaysNothing() {
        let center = NoticeCenter()
        center.post(CancellationError())
        #expect(center.notices.isEmpty)
        #expect(center.failuresPosted == 0)
        center.post(RemoteError.noRemotes, during: "Fetch")
        center.post(Notice(.success, title: "Pushed", message: ""))
        #expect(center.failuresPosted == 1)
        #expect(center.notices.count == 2)
    }

    @MainActor
    @Test func aPushOffersThePullRequestTheServerSuggests() throws {
        let said = [
            "Create a pull request for 'topic' on GitHub by visiting:",
            "https://github.com/example/app/pull/new/topic"
        ]
        let notice = try #require(RepositoryModel.serverOffer(after: "Push", said: said))
        #expect(notice.kind == .success)
        #expect(notice.recoveries == [
            .open(try #require(URL(string: "https://github.com/example/app/pull/new/topic")), title: "Create Pull Request")
        ])
        #expect(notice.detail == said.joined(separator: "\n"))
        // Only a push: a fetch that mentions a page is not an offer.
        #expect(RepositoryModel.serverOffer(after: "Fetch “origin”", said: said) == nil)
        #expect(RepositoryModel.serverOffer(after: "Push", said: ["Processed 1 reference."]) == nil)
    }

    @MainActor
    @Test func theLogCountsFailuresNotYetSeen() {
        let log = ActivityLog()
        let fetch = log.begin("Fetch", repository: "app", isBackground: true)
        log.finish(fetch, error: RemoteError.noRemotes)
        let push = log.begin("Push", repository: "app")
        log.finish(push, error: nil, said: ["Processed 1 reference."])
        #expect(log.unseenFailures == 1)
        #expect(log.entries.first?.said == ["Processed 1 reference."])
        log.markSeen()
        #expect(log.unseenFailures == 0)
    }
}
