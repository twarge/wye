import Foundation
import GitKit
import Testing

/// What git leaves conflicted, sorted.
private func unmerged(_ fixture: Fixture) throws -> [String] {
    try fixture.git("diff", "--name-only", "--diff-filter=U").split(separator: "\n").map(String.init).sorted()
}

/// The state a preview must leave alone.
private func untouched(_ fixture: Fixture) throws -> [String] {
    let index = try Data(contentsOf: fixture.url.appending(path: ".git/index"))
    return [
        try fixture.git("status", "--porcelain=v2", "--branch", "--untracked-files=all"),
        try fixture.git("for-each-ref", "--format=%(refname) %(objectname)"),
        index.base64EncodedString(),
    ]
}

private func sorted(_ verdict: MergePreview.Verdict) -> MergePreview.Verdict {
    if case .conflicts(let paths) = verdict { .conflicts(paths.sorted()) } else { verdict }
}

/// `main` and `topic` diverge from `Base`; `topic` changes the files named
/// in `topicFiles`, `main` those in `mainFiles`, each to its own branch's text.
private func diverged(mainFiles: [String], topicFiles: [String], base: [String] = ["a.txt", "b.txt", "c.txt"]) throws -> Fixture {
    let fixture = try Fixture()
    for path in base {
        try fixture.write("one\ntwo\nthree\n", to: path)
    }
    try fixture.git("add", ".")
    try fixture.git("commit", "--quiet", "-m", "Base")
    try fixture.git("checkout", "--quiet", "-b", "topic")
    for path in topicFiles {
        try fixture.commit(path, "one\ntopic\nthree\n", message: "Topic \(path)")
    }
    try fixture.git("checkout", "--quiet", "main")
    for path in mainFiles {
        try fixture.commit(path, "one\nmain\nthree\n", message: "Main \(path)")
    }
    return fixture
}

@Suite struct MergePreviewTests {
    static let cases: [(String, main: [String], topic: [String], expected: MergePreview.Verdict)] = [
        ("fast-forward", [], ["a.txt"], .fastForward),
        ("up to date", ["a.txt"], [], .upToDate),
        ("clean", ["a.txt"], ["b.txt"], .clean),
        ("one conflict", ["a.txt", "b.txt"], ["a.txt", "c.txt"], .conflicts(["a.txt"])),
        ("three conflicts", ["a.txt", "b.txt", "c.txt"], ["a.txt", "b.txt", "c.txt"], .conflicts(["a.txt", "b.txt", "c.txt"])),
        ("added on both sides", ["new.txt"], ["new.txt"], .conflicts(["new.txt"])),
    ]

    @Test(arguments: cases.indices)
    func mergeVerdictMatchesWhatGitDoes(_ position: Int) async throws {
        let (name, main, topic, expected) = Self.cases[position]
        let fixture = try diverged(mainFiles: main, topicFiles: topic)
        defer { fixture.remove() }
        try fixture.write("local change\n", to: "untracked.txt")
        let before = try untouched(fixture)

        let preview = try await fixture.open().previewMerge(of: "refs/heads/topic")
        #expect(sorted(preview.verdict) == expected, "\(name)")
        #expect(try untouched(fixture) == before, "the preview changed the repository")

        let head = try fixture.git("rev-parse", "HEAD")
        let output = (try? fixture.git("merge", "--no-edit", "topic")) ?? "failed"
        switch expected {
        case .upToDate: #expect(try fixture.git("rev-parse", "HEAD") == head)
        case .fastForward: #expect(output.contains("Fast-forward"))
        case .clean: #expect(try fixture.parentCounts().first == 2)
        case .conflicts(let paths): #expect(try unmerged(fixture) == paths)
        }
    }

    @Test func modifyDeleteConflictsAreListed() async throws {
        let fixture = try diverged(mainFiles: ["a.txt"], topicFiles: ["b.txt"])
        defer { fixture.remove() }
        try fixture.git("rm", "--quiet", "b.txt")
        try fixture.git("commit", "--quiet", "-m", "Delete b")
        let preview = try await fixture.open().previewMerge(of: "topic")
        _ = try? fixture.git("merge", "--no-edit", "topic")
        #expect(preview.verdict == .conflicts(try unmerged(fixture)))
        #expect(try unmerged(fixture) == ["b.txt"])
    }

    @Test func aBranchWithNoCommitsFastForwards() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "a\n", message: "A")
        try fixture.git("checkout", "--quiet", "--orphan", "empty")
        try fixture.git("rm", "--quiet", "-rf", ".")
        #expect(try await fixture.open().previewMerge(of: "refs/heads/main").verdict == .fastForward)
    }

    @Test func cancelledPreviewsStop() async throws {
        let fixture = try diverged(mainFiles: ["a.txt"], topicFiles: ["b.txt"])
        defer { fixture.remove() }
        let repository = try fixture.open()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.previewMerge(of: "refs/heads/topic")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct ReplayPreviewTests {
    /// `work` has three commits of its own, the second of which conflicts
    /// with `main` in a.txt and b.txt.
    private func topicWithAConflictInTheMiddle() throws -> (Fixture, commits: [String]) {
        let fixture = try diverged(mainFiles: ["a.txt", "b.txt"], topicFiles: [])
        try fixture.git("checkout", "--quiet", "-b", "work", "HEAD~2")
        let first = try fixture.commit("c.txt", "one\ntopic\nthree\n", message: "Topic c")
        try fixture.write("one\ntopic\nthree\n", to: "a.txt")
        try fixture.write("one\ntopic\nthree\n", to: "b.txt")
        try fixture.git("commit", "--quiet", "-am", "Topic a and b")
        let second = try fixture.git("rev-parse", "HEAD")
        let third = try fixture.commit("d.txt", "new\n", message: "Topic d")
        return (fixture, [first, second, third])
    }

    @Test func rebaseStopsWhereGitStops() async throws {
        let (fixture, commits) = try topicWithAConflictInTheMiddle()
        defer { fixture.remove() }
        let before = try untouched(fixture)
        let preview = try await fixture.open().previewRebase(onto: "refs/heads/main")
        #expect(try untouched(fixture) == before)
        #expect(preview.commitCount == 3)
        #expect(preview.stoppingStep == 2)
        #expect(preview.stoppingCommit?.hex == commits[1])

        _ = try? fixture.git("rebase", "main")
        #expect(sorted(preview.verdict) == .conflicts(try unmerged(fixture)))
        #expect(try fixture.git("rev-parse", "REBASE_HEAD") == commits[1])
    }

    @Test func cleanRebaseFastForwardAndUpToDate() async throws {
        let clean = try diverged(mainFiles: ["a.txt"], topicFiles: ["b.txt", "c.txt"])
        defer { clean.remove() }
        try clean.git("checkout", "--quiet", "topic")
        let preview = try await clean.open().previewRebase(onto: "refs/heads/main")
        #expect(preview.verdict == .clean)
        #expect(preview.commitCount == 2)
        try clean.git("rebase", "--quiet", "main")
        #expect(try clean.git("status", "--porcelain") == "")

        let behind = try diverged(mainFiles: ["a.txt"], topicFiles: [])
        defer { behind.remove() }
        try behind.git("checkout", "--quiet", "topic")
        #expect(try await behind.open().previewRebase(onto: "refs/heads/main").verdict == .fastForward)
        try behind.git("checkout", "--quiet", "main")
        #expect(try await behind.open().previewRebase(onto: "refs/heads/topic").verdict == .upToDate)
    }

    @Test func cherryPickStopsWhereGitStops() async throws {
        let (fixture, commits) = try topicWithAConflictInTheMiddle()
        defer { fixture.remove() }
        try fixture.git("checkout", "--quiet", "main")
        let preview = try await fixture.open().previewCherryPick(commits.compactMap(OID.init(hex:)))
        #expect(preview.stoppingCommit?.hex == commits[1])
        #expect(preview.stoppingStep == 2)

        _ = try? fixture.git("cherry-pick", commits[0], commits[1], commits[2])
        #expect(sorted(preview.verdict) == .conflicts(try unmerged(fixture)))
        #expect(try fixture.git("rev-parse", "CHERRY_PICK_HEAD") == commits[1])

        let clean = try await fixture.open().previewCherryPick([OID(hex: commits[2])!])
        #expect(clean.verdict == .clean)
    }

    @Test func revertPreviewMatchesGit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "one\n", message: "One")
        let two = try fixture.commit("a.txt", "two\n", message: "Two")
        let other = try fixture.commit("b.txt", "b\n", message: "Other")
        try fixture.commit("a.txt", "three\n", message: "Three")
        let repository = try fixture.open()
        #expect(try await repository.previewRevert([OID(hex: other)!]).verdict == .clean)
        let preview = try await repository.previewRevert([OID(hex: two)!])
        _ = try? fixture.git("revert", "--no-edit", two)
        #expect(preview.verdict == .conflicts(try unmerged(fixture)))
        #expect(try unmerged(fixture) == ["a.txt"])
    }
}
