import Foundation
import GitKit
import Testing

/// A commit that changes one file, adds one and deletes one.
@discardableResult
private func changes(_ fixture: Fixture) throws -> String {
    try fixture.commit("a.txt", "one\ntwo\nthree\n", message: "Base")
    try fixture.commit("gone.txt", "going\n", message: "Doomed")
    try fixture.write("one\n2\nthree\n", to: "a.txt")
    try fixture.write("new\n", to: "folder/new.txt")
    try fixture.git("rm", "--quiet", "gone.txt")
    try fixture.git("add", "a.txt", "folder/new.txt")
    try fixture.git("commit", "--quiet", "-m", "Change things: a, new & gone", "-m", "With a body.")
    return try fixture.git("rev-parse", "HEAD")
}

@Suite struct PatchFileTests {
    @Test func aSavedPatchAppliesWithGitAm() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tip = try changes(fixture)
        let patch = try await fixture.open().formatPatch(for: OID(hex: tip)!)
        #expect(patch.hasPrefix("From \(tip) "))
        #expect(patch.contains("Subject: [PATCH] Change things: a, new & gone"))

        let file = fixture.url.appendingPathExtension("patch")
        defer { try? FileManager.default.removeItem(at: file) }
        try patch.write(to: file, atomically: true, encoding: .utf8)
        try fixture.git("reset", "--quiet", "--hard", "HEAD~1")
        try fixture.git("apply", "--check", file.path)
        // The same changes as git's own patch for the commit.
        let gitPatch = try fixture.git("format-patch", "-1", "--stdout", tip)
        let gitFile = fixture.url.appendingPathExtension("git.patch")
        defer { try? FileManager.default.removeItem(at: gitFile) }
        try gitPatch.write(to: gitFile, atomically: true, encoding: .utf8)
        #expect(try fixture.git("apply", "--numstat", file.path) == fixture.git("apply", "--numstat", gitFile.path))

        try fixture.git("am", "--quiet", file.path)
        #expect(try fixture.git("rev-parse", "HEAD^{tree}") == fixture.git("rev-parse", "\(tip)^{tree}"))
        #expect(try fixture.git("log", "-1", "--format=%an <%ae>%n%B") == fixture.git("log", "-1", "--format=%an <%ae>%n%B", tip))
    }

    @Test func aMergeCannotBeSaved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "a\n", message: "A")
        try fixture.git("checkout", "--quiet", "-b", "topic")
        try fixture.commit("b.txt", "b\n", message: "B")
        try fixture.git("checkout", "--quiet", "main")
        try fixture.commit("c.txt", "c\n", message: "C")
        try fixture.git("merge", "--quiet", "--no-edit", "topic")
        let merge = try OID(hex: fixture.git("rev-parse", "HEAD"))!
        await #expect(throws: PatchFileError.mergeCommit) { try await fixture.open().formatPatch(for: merge) }
    }

    @Test func fileNamesMatchGitFormatPatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "a\n", message: "A")
        let repository = try fixture.open()
        let folder = fixture.url.appendingPathExtension("patches")
        defer { try? FileManager.default.removeItem(at: folder) }
        let subjects = ["Fix the build", "Add “quotes”, commas & more!", "...dots...", "x/y: path-like_name", "A very long subject line that goes on and on, well past the limit git sets"]
        for (index, subject) in subjects.enumerated() {
            try fixture.commit("a.txt", "\(index)\n", message: subject)
            let commit = try await repository.commit(OID(hex: fixture.git("rev-parse", "HEAD"))!)
            let written = try fixture.git("format-patch", "-1", "-o", folder.path, "HEAD")
            #expect(Repository.patchFileName(for: commit) == written.lastPathComponent, "\(subject)")
        }
    }

    @Test func gitPatchesApplyToEachTarget() async throws {
        for target in PatchTarget.allCases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let tip = try changes(fixture)
            let patch = Data(try fixture.git("format-patch", "-1", "--stdout", tip).utf8 + [10])
            try fixture.git("reset", "--quiet", "--hard", "HEAD~1")
            try fixture.write("untouched\n", to: "local.txt")

            try await fixture.open().applyPatch(patch, to: target)
            switch target {
            case .workingTree:
                #expect(try fixture.git("diff", "--cached") == "")
                #expect(try fixture.textOfFile("a.txt") == "one\n2\nthree\n")
                #expect(try fixture.textOfFile("folder/new.txt") == "new\n")
                #expect(!fixture.fileExists("gone.txt"))
            case .workingTreeAndIndex:
                #expect(try fixture.git("diff", "--cached", tip) == "")
                #expect(try fixture.git("diff", tip, "--", "a.txt", "folder", "gone.txt") == "")
            case .index:
                #expect(try fixture.git("diff", "--cached", tip) == "")
                #expect(try fixture.textOfFile("a.txt") == "one\ntwo\nthree\n")
            }
            #expect(try fixture.textOfFile("local.txt") == "untouched\n")
        }
    }

    @Test func aPatchThatDoesNotApplyChangesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tip = try changes(fixture)
        let patch = Data(try fixture.git("format-patch", "-1", "--stdout", tip).utf8 + [10])
        try fixture.git("reset", "--quiet", "--hard", "HEAD~1")
        try fixture.write("one\nTWO\nthree\n", to: "a.txt")
        let status = try fixture.git("status", "--porcelain")
        let repository = try fixture.open()
        #expect(try await repository.patchApplies(patch, to: .workingTree) == false)
        await #expect(throws: PatchFileError.self) { try await repository.applyPatch(patch, to: .workingTree) }
        #expect(try fixture.git("status", "--porcelain") == status)
        #expect(!fixture.fileExists("folder/new.txt"))
        await #expect(throws: PatchFileError.notAPatch) { try await repository.applyPatch(Data("hello\n".utf8), to: .index) }
    }

    @Test func applyingAPatchIsUndoable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tip = try changes(fixture)
        let patch = Data(try fixture.git("format-patch", "-1", "--stdout", tip).utf8 + [10])
        try fixture.git("reset", "--quiet", "--hard", "HEAD~1")
        let repository = try fixture.open()
        let status = try fixture.git("status", "--porcelain")
        let start = await repository.beginUndoable(.applyPatch(toIndex: false))
        try await repository.applyPatch(patch, to: .workingTreeAndIndex)
        guard case .recorded(let record) = await repository.finishUndoable(start) else {
            Issue.record("No record")
            return
        }
        try await repository.applyUndo(record, .undo)
        #expect(try fixture.git("status", "--porcelain") == status)
        #expect(!fixture.fileExists("folder/new.txt"))
        #expect(try fixture.textOfFile("gone.txt") == "going\n")
    }

    // MARK: Rewording

    @Test func rewordingMatchesGitAmendOnly() async throws {
        let (ours, git) = try Fixture.twins { fixture in
            try fixture.commit("a.txt", "a\n", message: "A")
            try fixture.commit("b.txt", "b\n", message: "Tpyo")
            try fixture.write("staged\n", to: "a.txt")
            try fixture.git("add", "a.txt")
        }
        defer { ours.remove(); git.remove() }
        let repository = try ours.open()
        let start = await repository.beginUndoable(.reword)
        try await repository.rewordHead(message: "Typo fixed\n\nAnd a body.")
        try git.git("commit", "--quiet", "--amend", "--only", "-m", "Typo fixed", "-m", "And a body.")

        #expect(try ours.logFormat("%T %P %an <%ae> %ad | %B") == git.logFormat("%T %P %an <%ae> %ad | %B"))
        // The staged change stays staged, outside the commit.
        #expect(try ours.git("diff", "--cached", "--name-only") == "a.txt")
        guard case .recorded(let record) = await repository.finishUndoable(start) else {
            Issue.record("No record")
            return
        }
        try await repository.applyUndo(record, .undo)
        #expect(try ours.logFormat("%s") == ["Tpyo", "A"])
        #expect(try ours.git("diff", "--cached", "--name-only") == "a.txt")
    }

    @Test func aPushedCommitIsFound() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.commit("a.txt", "a\n", message: "A")
        let first = try OID(hex: fixture.git("rev-parse", "HEAD"))!
        try fixture.git("update-ref", "refs/remotes/origin/main", "HEAD")
        try fixture.commit("b.txt", "b\n", message: "B")
        let second = try OID(hex: fixture.git("rev-parse", "HEAD"))!
        let repository = try fixture.open()
        #expect(try await repository.remoteBranch(containing: first) == "origin/main")
        #expect(try await repository.remoteBranch(containing: second) == nil)
    }
}

extension String {
    fileprivate var lastPathComponent: String {
        split(separator: "/").last.map(String.init) ?? self
    }
}
