import Foundation
import Testing
@testable import GitKit

@Suite struct ServerMessagesTests {
    @Test func keepsWhatTheServerSaidAndDropsItsCounting() {
        let output = "Enumerating objects: 5, done.\n"
            + "Counting objects:  20% (1/5)\rCounting objects: 100% (5/5), done.\n"
            + "Compressing objects: 100% (3/3), done.\n"
            + "Total 5 (delta 1), reused 0 (delta 0), pack-reused 0\n"
            + "\n"
            + "Create a pull request for 'topic' on GitHub by visiting:\n"
            + "     https://github.com/example/app/pull/new/topic\n"
            + "\n"
        #expect(ServerMessages.lines(in: output) == [
            "Create a pull request for 'topic' on GitHub by visiting:",
            "https://github.com/example/app/pull/new/topic"
        ])
        #expect(ServerMessages.lines(in: "").isEmpty)
    }

    @Test func aLineWrittenOverItselfCountsOnce() {
        #expect(ServerMessages.lines(in: "hook: checking\rhook: rejected, no ticket number\n")
            == ["hook: rejected, no ticket number"])
    }

    @Test func findsThePageToOpen() throws {
        let github = try #require(ServerMessages.link(in: ["visit:", "https://github.com/example/app/pull/new/topic"]))
        #expect(github.opensPullRequest)
        #expect(github.url.absoluteString == "https://github.com/example/app/pull/new/topic")
        let gitlab = try #require(ServerMessages.link(in: [
            "To create a merge request for topic, visit:",
            "https://gitlab.com/example/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=topic"
        ]))
        #expect(gitlab.opensPullRequest)
        let other = try #require(ServerMessages.link(in: ["See https://example.com/status for details"]))
        #expect(!other.opensPullRequest)
        #expect(ServerMessages.link(in: ["Processed 1 reference."]) == nil)
    }

    @Test func aTransferKeepsWhatItHearsUpToALimit() {
        let transfer = Transfer()
        let line = Array("remote says hello\n".utf8)
        line.withUnsafeBufferPointer { transfer.hear($0) }
        #expect(transfer.serverOutput == "remote says hello\n")
        let flood = [UInt8](repeating: UInt8(ascii: "x"), count: Transfer.serverOutputLimit)
        flood.withUnsafeBufferPointer { transfer.hear($0) }
        flood.withUnsafeBufferPointer { transfer.hear($0) }
        #expect(transfer.serverOutput.utf8.count == Transfer.serverOutputLimit)
    }
}
