import Foundation
import GitKit
import Testing

@Suite struct RepositoryTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    @Test func opensOnlyTheTopFolderOfARepository() throws {
        defer { fixture.remove() }
        try fixture.write("x", to: "folder/file.txt")
        #expect(Repository.exists(at: fixture.url))
        #expect(!Repository.exists(at: fixture.url.appending(path: "folder")))
        #expect(throws: GitError.self) { try Repository(at: fixture.url.appending(path: "folder")) }
    }

    @Test func aNewRepositoryHasAnUnbornHead() async throws {
        defer { fixture.remove() }
        let snapshot = try await fixture.open().snapshot()
        #expect(snapshot.head == .unborn(name: "refs/heads/main"))
        #expect(snapshot.branches.isEmpty)
        #expect(try await fixture.open().commitCount(in: .allReferences) == 0)
    }

    @Test func snapshotListsBranchesTagsRemotesAndStashes() async throws {
        defer { fixture.remove() }
        let first = try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.git("tag", "v1.0")
        try fixture.git("tag", "-a", "v1.1", "-m", "Annotated")

        // A bare clone to stand as the remote, then one commit past it.
        let remote = fixture.url.appendingPathExtension("remote")
        defer { try? FileManager.default.removeItem(at: remote) }
        try fixture.git("clone", "--quiet", "--bare", ".", remote.path)
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("fetch", "--quiet", "origin")
        try fixture.git("branch", "--set-upstream-to=origin/main")
        let second = try fixture.commit("a.txt", "two\n", message: "Second")
        try fixture.git("branch", "feature/login", first)

        try fixture.write("stashed\n", to: "a.txt")
        try fixture.git("stash", "push", "--quiet", "-m", "work in progress")

        let snapshot = try await fixture.open().snapshot()
        #expect(snapshot.head == .branch(name: "refs/heads/main", target: OID(hex: second)!))
        #expect(snapshot.state == .clean)
        #expect(snapshot.branches.map(\.name) == ["feature/login", "main"])

        let main = try #require(snapshot.branches.last)
        #expect(main.isHead)
        #expect(main.upstream?.name == "origin/main")
        #expect(main.upstream?.ahead == 1)
        #expect(main.upstream?.behind == 0)
        #expect(snapshot.branches.first?.upstream == nil)

        #expect(snapshot.tags.map(\.name) == ["v1.1", "v1.0"])
        #expect(snapshot.tags.map(\.isAnnotated) == [true, false])
        #expect(snapshot.tags.allSatisfy { $0.target == OID(hex: first) })

        let origin = try #require(snapshot.remotes.first)
        #expect(origin.name == "origin")
        #expect(origin.url == remote.path)
        // Fetching also records which branch the remote has checked out.
        #expect(origin.branches.map(\.name) == ["origin/HEAD", "origin/main"])
        #expect(origin.branches.map(\.nameWithoutRemote) == ["HEAD", "main"])

        #expect(snapshot.stashes.count == 1)
        #expect(snapshot.stashes.first?.message == "On main: work in progress")
    }

    @Test func historyListsChildrenBeforeParents() async throws {
        defer { fixture.remove() }
        let first = try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        let topic = try fixture.commit("b.txt", "topic\n", message: "Topic work\n\nWith a body.\nOn two lines.")
        try fixture.git("checkout", "--quiet", "main")
        let second = try fixture.commit("a.txt", "two\n", message: "Second")
        try fixture.git("merge", "--quiet", "--no-ff", "-m", "Merge topic", "topic")
        let merge = try fixture.git("rev-parse", "HEAD")

        let repository = try fixture.open()
        #expect(try await repository.commitCount(in: .allReferences) == 4)
        #expect(try await repository.commitCount(in: .reference("refs/heads/topic")) == 2)

        let cursor = try await repository.openHistory(.allReferences)
        let page = try await repository.nextCommits(from: cursor, limit: 3)
        let rest = try await repository.nextCommits(from: cursor, limit: 3)
        #expect(try await repository.nextCommits(from: cursor, limit: 3).isEmpty)
        await repository.closeHistory(cursor)

        let commits = page + rest
        #expect(commits.count == 4)
        #expect(commits.first?.id.hex == merge)
        #expect(commits.last?.id.hex == first)
        #expect(commits.first?.parentIDs.map(\.hex) == [second, topic])
        #expect(commits.first?.isMerge == true)

        let topicCommit = try await repository.commit(OID(hex: topic)!)
        #expect(topicCommit.summary == "Topic work")
        #expect(topicCommit.body == "With a body.\nOn two lines.")
        #expect(topicCommit.author.name == "Test Author")
        #expect(topicCommit.author.email == "author@example.com")
        #expect(topicCommit.author.timeZone.secondsFromGMT() == 3600)
        #expect(topicCommit.author.date == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05+01:00"))
    }

    @Test func changesDescribeACommit() async throws {
        defer { fixture.remove() }
        try fixture.commit("notes.txt", "one\ntwo\nthree\n", message: "First")
        try fixture.write("one\n2\nthree\nfour\n", to: "notes.txt")
        try fixture.write("new\n", to: "added.txt")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "-m", "Second")
        let second = try fixture.git("rev-parse", "HEAD")
        try fixture.git("mv", "added.txt", "moved.txt")
        try fixture.git("commit", "--quiet", "-m", "Rename")
        let rename = try fixture.git("rev-parse", "HEAD")

        let repository = try fixture.open()
        let files = try await repository.changes(in: OID(hex: second)!)
        #expect(files.map(\.path) == ["added.txt", "notes.txt"])
        #expect(files.map(\.change) == [.added, .modified])

        let notes = try #require(files.last)
        #expect(notes.additions == 2)
        #expect(notes.deletions == 1)
        #expect(notes.hunks.count == 1)
        #expect(notes.hunks.first?.header == "@@ -1,3 +1,4 @@")
        let lines = try #require(notes.hunks.first?.lines)
        #expect(lines.map(\.kind) == [.context, .deletion, .addition, .context, .addition])
        #expect(lines.map(\.text) == ["one", "two", "2", "three", "four"])
        #expect(lines.map(\.oldNumber) == [1, 2, nil, 3, nil])
        #expect(lines.map(\.newNumber) == [1, nil, 2, 3, 4])

        let renamed = try await repository.changes(in: OID(hex: rename)!)
        #expect(renamed.count == 1)
        #expect(renamed.first?.change == .renamed)
        #expect(renamed.first?.oldPath == "added.txt")
        #expect(renamed.first?.path == "moved.txt")
    }

    @Test func theFirstCommitIsComparedWithNothing() async throws {
        defer { fixture.remove() }
        let first = try fixture.commit("a.txt", "one\n", message: "First")
        let files = try await fixture.open().changes(in: OID(hex: first)!)
        #expect(files.map(\.change) == [.added])
        #expect(files.first?.additions == 1)
    }

    @Test func stagingAndCommittingMatchGit() async throws {
        defer { fixture.remove() }
        try fixture.commit("kept.txt", "one\n", message: "First")
        try fixture.commit("doomed.txt", "bye\n", message: "Second")
        try fixture.write("one\ntwo\n", to: "kept.txt")
        try fixture.write("fresh\n", to: "folder/new.txt")
        try FileManager.default.removeItem(at: fixture.url.appending(path: "doomed.txt"))

        let repository = try fixture.open()
        var status = try await repository.status()
        #expect(status.map(\.path) == ["doomed.txt", "folder/new.txt", "kept.txt"])
        #expect(status.map(\.unstaged) == [.deleted, .untracked, .modified])
        #expect(status.allSatisfy { $0.staged == nil })

        let unstaged = try #require(try await repository.unstagedDiff(of: "kept.txt"))
        #expect(unstaged.additions == 1)
        #expect(try await repository.stagedDiff(of: "kept.txt") == nil)
        let untracked = try #require(try await repository.unstagedDiff(of: "folder/new.txt"))
        #expect(untracked.hunks.first?.lines.map(\.text) == ["fresh"])

        try await repository.stage(["kept.txt", "folder/new.txt", "doomed.txt"])
        status = try await repository.status()
        #expect(status.map(\.staged) == [.deleted, .added, .modified])
        #expect(status.allSatisfy { $0.unstaged == nil })
        #expect(try fixture.git("diff", "--cached", "--name-status") == "D\tdoomed.txt\nA\tfolder/new.txt\nM\tkept.txt")
        #expect(try await repository.stagedDiff(of: "kept.txt")?.additions == 1)

        try await repository.unstage(["doomed.txt"])
        #expect(try fixture.git("diff", "--cached", "--name-only") == "folder/new.txt\nkept.txt")

        #expect(await repository.identity() == GitIdentity(name: "Test Author", email: "author@example.com"))
        let id = try await repository.commit(message: "  Third\n\nBody.  ")
        #expect(try fixture.git("rev-parse", "HEAD") == id.hex)
        #expect(try fixture.git("log", "-1", "--format=%an <%ae>%n%B") == "Test Author <author@example.com>\nThird\n\nBody.")
        #expect(try fixture.git("status", "--porcelain") == "D doomed.txt")
    }

    @Test func stagingWorksBeforeTheFirstCommit() async throws {
        defer { fixture.remove() }
        try fixture.write("one\n", to: "a.txt")
        try fixture.write("two\n", to: "b.txt")
        let repository = try fixture.open()
        try await repository.stage(["a.txt", "b.txt"])
        try await repository.unstage(["b.txt"])
        #expect(try await repository.status().map(\.staged) == [.added, nil])
        let id = try await repository.commit(message: "First")
        #expect(try await repository.head() == .branch(name: "refs/heads/main", target: id))
        #expect(try fixture.git("ls-tree", "--name-only", "HEAD") == "a.txt")
    }

    @Test func committingAMergeRecordsBothParents() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "base\n", message: "Base")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        let topic = try fixture.commit("a.txt", "topic\n", message: "Topic")
        try fixture.git("checkout", "--quiet", "main")
        let main = try fixture.commit("a.txt", "main\n", message: "Main")
        #expect(throws: (any Error).self) { try fixture.git("merge", "topic") }

        let repository = try fixture.open()
        #expect(try await repository.snapshot().state == .merging)
        #expect(try await repository.status().first?.isConflicted == true)

        try fixture.write("resolved\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let id = try await repository.commit(message: "Merge topic")
        #expect(try await repository.commit(id).parentIDs.map(\.hex) == [main, topic])
        #expect(try await repository.snapshot().state == .clean)
    }

    @Test func branchesCanBeCreatedAndCheckedOut() async throws {
        defer { fixture.remove() }
        let first = try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.commit("a.txt", "two\n", message: "Second")

        let repository = try fixture.open()
        let name = try await repository.createBranch(named: "old", at: OID(hex: first)!)
        #expect(name == "refs/heads/old")
        try await repository.checkOut(branch: name)
        #expect(try fixture.git("symbolic-ref", "HEAD") == "refs/heads/old")
        #expect(try String(contentsOf: fixture.url.appending(path: "a.txt"), encoding: .utf8) == "one\n")

        // A switch that would overwrite a local change is refused.
        try fixture.write("local edit\n", to: "a.txt")
        await #expect(throws: GitError.self) { try await repository.checkOut(branch: "refs/heads/main") }
        #expect(try fixture.git("symbolic-ref", "HEAD") == "refs/heads/old")
    }
}

@Suite struct ObjectIDTests {
    @Test func hexRoundTrips() throws {
        let hex = "d86a667087d0b71ab2ded6b4cf305101d67190b4"
        let id = try #require(OID(hex: hex))
        #expect(id.hex == hex)
        #expect(id.abbreviated() == "d86a6670")
        #expect(OID(hex: hex.uppercased()) == id)
        #expect(OID(hex: "d86a") == nil)
        #expect(OID(hex: hex + "00") == nil)
        #expect(OID(hex: String(repeating: "z", count: 40)) == nil)
    }
}
