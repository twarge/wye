import Foundation
import Testing
@testable import TwigUI

@Suite struct RepositoryChangeFilterTests {
    let filter = RepositoryChangeFilter(
        locations: RepositoryLocations(workTree: "/r/project", gitDirectory: "/r/project/.git")
    )

    @Test func keepsWhatChangesTheWindow() {
        for path in [
            "HEAD", "index", "packed-refs", "config", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
            "refs/heads/main", "refs/heads/feature/one", "refs/remotes/origin/main", "refs/tags/v1", "refs/stash",
            "rebase-merge/done", "rebase-apply", "sequencer/todo", "info/exclude", "worktrees/other",
            "modules/lib/HEAD"
        ] {
            #expect(filter.classify("/r/project/.git/" + path) == .gitDirectory, "\(path)")
        }
        #expect(filter.classify("/r/project/Sources/a.swift") == .workingTree("Sources/a.swift"))
        #expect(filter.classify("/r/project/README.md") == .workingTree("README.md"))
        #expect(filter.classify("/r/project/.gitignore") == .workingTree(".gitignore"))
    }

    @Test func dropsGitsOwnChurn() {
        for path in [
            "objects/ab/cdef", "objects/pack/pack-1.pack", "objects", "logs/HEAD", "logs/refs/heads/main",
            "index.lock", "HEAD.lock", "refs/heads/main.lock", "packed-refs.lock", "FETCH_HEAD", "ORIG_HEAD",
            "COMMIT_EDITMSG", "hooks/pre-commit", "description", "gc.pid", "worktrees/other/index",
            "worktrees/other/logs/HEAD", "modules/lib/objects/ab/cd", "modules/lib/index", ""
        ] {
            #expect(filter.classify("/r/project/.git/" + path) == nil, "\(path)")
        }
        #expect(filter.classify("/r/project/.git") == nil)
        #expect(filter.classify("/r/project") == nil)
        #expect(filter.classify("/r/elsewhere/file") == nil)
        #expect(filter.classify("/r/project-two/file") == nil)
        // A repository nested in the tree.
        #expect(filter.classify("/r/project/vendor/lib/.git/index") == nil)
    }

    @Test func rescansWhenTheFileSystemLostTrack() {
        #expect(filter.classify("/r/project/.git/objects", isRescan: true) == .rescan)
    }

    @Test func readsALinkedWorktreesGitDirectory() {
        let filter = RepositoryChangeFilter(locations: RepositoryLocations(
            workTree: "/r/wt", gitDirectory: "/r/main/.git/worktrees/wt", commonDirectory: "/r/main/.git"
        ))
        #expect(filter.classify("/r/main/.git/worktrees/wt/HEAD") == .gitDirectory)
        #expect(filter.classify("/r/main/.git/worktrees/wt/index") == .gitDirectory)
        #expect(filter.classify("/r/main/.git/refs/heads/main") == .gitDirectory)
        #expect(filter.classify("/r/main/.git/objects/ab/cd") == nil)
        #expect(filter.classify("/r/wt/file.txt") == .workingTree("file.txt"))
        #expect(filter.classify("/r/main/file.txt") == nil)
    }

    @Test func watchesEachFolderOnce() {
        #expect(RepositoryLocations(workTree: "/r/p", gitDirectory: "/r/p/.git").roots == ["/r/p"])
        #expect(RepositoryLocations(workTree: nil, gitDirectory: "/r/p.git").roots == ["/r/p.git"])
        #expect(Set(RepositoryLocations(
            workTree: "/r/wt", gitDirectory: "/r/main/.git/worktrees/wt", commonDirectory: "/r/main/.git"
        ).roots) == ["/r/wt", "/r/main/.git"])
    }

    @Test func findsTheGitDirectoryOfAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwigUITests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = folder.appending(path: "main")
        let worktree = folder.appending(path: "wt")
        try FileManager.default.createDirectory(at: main.appending(path: ".git/worktrees/wt"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/wt\n".write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: main.appending(path: ".git/worktrees/wt/commondir"), atomically: true, encoding: .utf8)

        let real = RepositoryLocations.realPath(folder.path)
        let plain = RepositoryLocations(repositoryURL: main, isBare: false)
        #expect(plain.workTree == real + "/main")
        #expect(plain.gitDirectory == real + "/main/.git")
        #expect(plain.commonDirectory == plain.gitDirectory)

        let linked = RepositoryLocations(repositoryURL: worktree, isBare: false)
        #expect(linked.workTree == real + "/wt")
        #expect(linked.gitDirectory == real + "/main/.git/worktrees/wt")
        #expect(linked.commonDirectory == real + "/main/.git")
    }
}

@Suite struct RefreshCoalescerTests {
    let start = ContinuousClock.now

    @Test func waitsForAQuietMoment() {
        var coalescer = RefreshCoalescer()
        #expect(coalescer.deadline == nil)
        coalescer.record(stamp: 1, at: start)
        coalescer.record(stamp: 2, at: start + .milliseconds(100))
        #expect(coalescer.deadline == start + .milliseconds(350))
        #expect(!coalescer.isDue(at: start + .milliseconds(300), isBusy: false))
        #expect(coalescer.isDue(at: start + .milliseconds(350), isBusy: false))
    }

    @Test func refreshesAStreamOfChangesAtLeastEverySecond() {
        var coalescer = RefreshCoalescer()
        for step in 0..<20 {
            coalescer.record(stamp: UInt64(step + 1), at: start + .milliseconds(100 * step))
        }
        #expect(coalescer.deadline == start + .seconds(1))
    }

    @Test func waitsWhileBusy() {
        var coalescer = RefreshCoalescer()
        coalescer.record(stamp: 5, at: start)
        #expect(!coalescer.isDue(at: start + .seconds(5), isBusy: true))
        #expect(coalescer.isDue(at: start + .seconds(5), isBusy: false))
    }

    @Test func dropsChangesARefreshAlreadyRead() {
        var coalescer = RefreshCoalescer()
        coalescer.record(stamp: 5, at: start)
        coalescer.refreshBegan(covering: 9)
        #expect(!coalescer.hasPending)
        // Stamped before the refresh began: it read them.
        let tooOld = coalescer.record(stamp: 7, at: start)
        #expect(!tooOld)
        #expect(!coalescer.hasPending)
        // After: still to be read.
        let newer = coalescer.record(stamp: 10, at: start)
        #expect(newer)
        coalescer.refreshBegan(covering: 9)
        #expect(coalescer.hasPending)
    }
}
