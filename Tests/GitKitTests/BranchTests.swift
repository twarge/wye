import Foundation
import GitKit
import Testing

@Suite struct BranchTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    @Test func renamingABranchKeepsItsUpstreamAndHead() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.git("branch", "topic")
        try fixture.git("branch", "--set-upstream-to=main", "topic")

        let repository = try fixture.open()
        let renamed = try await repository.renameBranch("refs/heads/topic", to: "feature/topic")
        #expect(renamed == "refs/heads/feature/topic")
        #expect(try fixture.git("branch", "--format=%(refname:short)") == "feature/topic\nmain")
        #expect(try fixture.git("rev-parse", "--abbrev-ref", "feature/topic@{upstream}") == "main")

        // Renaming the checked-out branch moves HEAD along with it.
        try await repository.renameBranch("refs/heads/main", to: "trunk")
        #expect(try fixture.git("symbolic-ref", "HEAD") == "refs/heads/trunk")

        await #expect(throws: GitError.self) {
            try await repository.renameBranch("refs/heads/trunk", to: "feature/topic")
        }
        try fixture.git("tag", "v1")
        await #expect(throws: BranchingError.notABranch("refs/tags/v1")) {
            try await repository.renameBranch("refs/tags/v1", to: "x")
        }
    }

    @Test func deletingRefusesAnUnmergedBranchUnlessForced() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.git("branch", "merged")
        try fixture.git("checkout", "--quiet", "-b", "unmerged")
        try fixture.commit("b.txt", "b\n", message: "Unmerged one")
        try fixture.commit("b.txt", "bb\n", message: "Unmerged two")
        try fixture.git("checkout", "--quiet", "main")

        let repository = try fixture.open()
        try await repository.deleteBranch("refs/heads/merged")
        #expect(try await repository.unmergedCommitCount(of: "refs/heads/unmerged") == 2)
        await #expect(throws: BranchingError.notMerged(branch: "unmerged", commits: 2)) {
            try await repository.deleteBranch("refs/heads/unmerged")
        }
        // git agrees that it is unmerged, and the refusal left it alone.
        #expect(throws: (any Error).self) { try fixture.git("branch", "-d", "unmerged") }
        #expect(try fixture.git("branch", "--format=%(refname:short)") == "main\nunmerged")

        try await repository.deleteBranch("refs/heads/unmerged", force: true)
        #expect(try fixture.git("branch", "--format=%(refname:short)") == "main")

        await #expect(throws: BranchingError.currentBranch("main")) {
            try await repository.deleteBranch("refs/heads/main", force: true)
        }
    }

    @Test func aBranchMergedIntoItsUpstreamCanBeDeleted() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.git("checkout", "--quiet", "-b", "base")
        try fixture.commit("b.txt", "b\n", message: "On base")
        try fixture.git("branch", "topic")
        try fixture.git("branch", "--set-upstream-to=base", "topic")
        try fixture.git("checkout", "--quiet", "main")

        // Not in HEAD (main), but in its upstream.
        let repository = try fixture.open()
        #expect(try await repository.unmergedCommitCount(of: "refs/heads/topic") == 0)
        try await repository.deleteBranch("refs/heads/topic")
        #expect(try fixture.git("branch", "--format=%(refname:short)") == "base\nmain")
    }

    @Test func upstreamsAreSetAndCleared() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        let remote = fixture.url.appendingPathExtension("remote")
        defer { try? FileManager.default.removeItem(at: remote) }
        try fixture.git("clone", "--quiet", "--bare", ".", remote.path)
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("fetch", "--quiet", "origin")

        let repository = try fixture.open()
        try await repository.setUpstream(of: "refs/heads/main", to: "refs/remotes/origin/main")
        #expect(try fixture.git("rev-parse", "--abbrev-ref", "main@{upstream}") == "origin/main")
        #expect(try fixture.git("config", "branch.main.remote") == "origin")
        #expect(try fixture.git("config", "branch.main.merge") == "refs/heads/main")
        #expect(try await repository.snapshot().branches.first?.upstream?.name == "origin/main")

        try await repository.setUpstream(of: "refs/heads/main", to: nil)
        #expect(throws: (any Error).self) { try fixture.git("rev-parse", "--abbrev-ref", "main@{upstream}") }
        #expect(try await repository.snapshot().branches.first?.upstream == nil)
    }

    @Test func aRemoteBranchIsCheckedOutAsATrackingBranch() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.git("branch", "feature/login")
        let remote = fixture.url.appendingPathExtension("remote")
        defer { try? FileManager.default.removeItem(at: remote) }
        try fixture.git("clone", "--quiet", "--bare", ".", remote.path)
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("fetch", "--quiet", "origin")
        try fixture.git("branch", "-D", "feature/login")

        let repository = try fixture.open()
        let local = try await repository.createTrackingBranch(for: "refs/remotes/origin/feature/login")
        #expect(local == "refs/heads/feature/login")
        #expect(try fixture.git("rev-parse", "--abbrev-ref", "feature/login@{upstream}") == "origin/feature/login")
        try await repository.checkOut(branch: local)
        #expect(try fixture.git("symbolic-ref", "HEAD") == "refs/heads/feature/login")

        // Asking again reuses it; a same-named branch tracking something else
        // is not taken over.
        #expect(try await repository.createTrackingBranch(for: "refs/remotes/origin/feature/login") == local)
        await #expect(throws: BranchingError.branchExists("main")) {
            try await repository.createTrackingBranch(for: "refs/remotes/origin/feature/login", named: "main")
        }
    }

    @Test func tagsAreCreatedAndDeleted() async throws {
        defer { fixture.remove() }
        let first = try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.commit("a.txt", "two\n", message: "Second")

        let repository = try fixture.open()
        let light = try await repository.createTag(named: "v1.0", at: OID(hex: first)!)
        #expect(light == "refs/tags/v1.0")
        #expect(try fixture.git("cat-file", "-t", "refs/tags/v1.0") == "commit")
        #expect(try fixture.git("rev-parse", "v1.0") == first)

        try await repository.createTag(named: "v1.1", at: OID(hex: first)!, message: "  Release 1.1\n\nNotes.  ")
        #expect(try fixture.git("cat-file", "-t", "refs/tags/v1.1") == "tag")
        #expect(try fixture.git("rev-parse", "v1.1^{commit}") == first)
        #expect(try fixture.git("tag", "-l", "--format=%(taggername) %(taggeremail)", "v1.1")
            == "Test Author <author@example.com>")
        #expect(try fixture.git("tag", "-l", "--format=%(contents)", "v1.1") == "Release 1.1\n\nNotes.")
        #expect(try await repository.snapshot().tags.map(\.isAnnotated) == [true, false])

        await #expect(throws: GitError.self) {
            try await repository.createTag(named: "v1.0", at: OID(hex: first)!)
        }

        try await repository.deleteTag("refs/tags/v1.0")
        try await repository.deleteTag("v1.1")
        #expect(try fixture.git("tag", "-l") == "")
    }

    @Test func checkingOutATagDetachesHead() async throws {
        defer { fixture.remove() }
        let first = try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.git("tag", "-a", "v1", "-m", "One")
        try fixture.commit("a.txt", "two\n", message: "Second")

        let repository = try fixture.open()
        try await repository.checkOut(tag: "refs/tags/v1")
        #expect(try await repository.head() == .detached(OID(hex: first)!))
        #expect(throws: (any Error).self) { try fixture.git("symbolic-ref", "-q", "HEAD") }
        #expect(try fixture.git("rev-parse", "HEAD") == first)
        #expect(try fixture.textOfFile("a.txt") == "one\n")
    }

    @Test func resetModesMatchGit() async throws {
        func build(_ fixture: Fixture) throws {
            try fixture.commit("a.txt", "one\n", message: "First")
            try fixture.commit("a.txt", "two\n", message: "Second")
            try fixture.commit("b.txt", "b\n", message: "Third")
            try fixture.write("local\n", to: "a.txt")
            try fixture.write("untracked\n", to: "u.txt")
        }
        for (mode, flag) in [(ResetMode.soft, "--soft"), (.mixed, "--mixed"), (.hard, "--hard")] {
            let (ours, git) = try Fixture.twins(build)
            defer { ours.remove(); git.remove() }
            let target = try ours.git("rev-parse", "HEAD~2")

            try await ours.open().reset(to: OID(hex: target)!, mode: mode)
            try git.git("reset", "--quiet", flag, target)

            #expect(try ours.git("rev-parse", "HEAD") == target)
            #expect(try ours.git("symbolic-ref", "HEAD") == "refs/heads/main")
            #expect(try ours.git("status", "--porcelain") == git.git("status", "--porcelain"))
            #expect(try ours.textOfFile("a.txt") == git.textOfFile("a.txt"))
            #expect(ours.fileExists("b.txt") == git.fileExists("b.txt"))
            // Untracked files survive even a hard reset.
            #expect(try ours.textOfFile("u.txt") == "untracked\n")
        }
    }

    @Test func aHardResetDiscardsLocalChanges() async throws {
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.write("lost\n", to: "a.txt")
        try fixture.write("staged\n", to: "s.txt")
        try fixture.git("add", "s.txt")

        let head = try fixture.git("rev-parse", "HEAD")
        try await fixture.open().reset(to: OID(hex: head)!, mode: .hard)
        #expect(try fixture.textOfFile("a.txt") == "one\n")
        #expect(!fixture.fileExists("s.txt"))
        #expect(try fixture.git("status", "--porcelain") == "")
    }
}
