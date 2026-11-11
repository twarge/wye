import Foundation
import GitKit
import Testing

/// The main branch and which branches are merged into it, against
/// `git branch --merged`.
@Suite struct BranchReviewTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
        try fixture.commit("a.txt", "one\n", message: "First")
    }

    @Test func mergedBranchesMatchGit() async throws {
        defer { fixture.remove() }
        try fixture.git("branch", "same")
        try fixture.git("checkout", "--quiet", "-b", "done")
        try fixture.commit("b.txt", "done\n", message: "Done")
        try fixture.git("checkout", "--quiet", "-b", "open")
        try fixture.commit("c.txt", "open\n", message: "Open")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.git("merge", "--quiet", "--no-ff", "--no-edit", "done")
        try fixture.git("checkout", "--quiet", "-b", "behind", "main~1")

        let repository = try fixture.open()
        let branches = try await repository.snapshot().branches.map(\.id)
        let review = try await repository.reviewBranches(branches, against: "refs/heads/main")

        let gitMerged = try fixture.git("branch", "--merged", "main", "--format=%(refname)")
            .split(separator: "\n").map(String.init).filter { $0 != "refs/heads/main" }
        #expect(review.merged == Set(gitMerged))
        #expect(review.merged == ["refs/heads/same", "refs/heads/done", "refs/heads/behind"])
        #expect(Set(review.tipDates.keys) == Set(branches))
        let date = try #require(review.tipDates["refs/heads/open"])
        #expect(date == ISO8601DateFormatter().date(from: "2026-01-02T02:04:05Z"))
    }

    @Test func theMainBranchFollowsOriginHead() async throws {
        defer { fixture.remove() }
        let remote = fixture.url.appendingPathExtension("remote.git")
        defer { try? FileManager.default.removeItem(at: remote) }
        try fixture.git("branch", "trunk")
        try fixture.git("clone", "--quiet", "--bare", ".", remote.path)
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("fetch", "--quiet", "origin")
        let repository = try fixture.open()

        // Without origin/HEAD, main.
        #expect(try await repository.mainBranch() == "refs/heads/main")
        try fixture.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
        #expect(try await repository.mainBranch() == "refs/heads/trunk")
        // The remote branch itself when there is no local one.
        try fixture.git("branch", "-D", "trunk")
        #expect(try await repository.mainBranch() == "refs/remotes/origin/trunk")
    }

    @Test func otherwiseMasterOrTheCurrentBranch() async throws {
        defer { fixture.remove() }
        try fixture.git("branch", "-m", "main", "master")
        let repository = try fixture.open()
        #expect(try await repository.mainBranch() == "refs/heads/master")
        try fixture.git("branch", "-m", "master", "work")
        #expect(try await repository.mainBranch() == "refs/heads/work")
    }
}
