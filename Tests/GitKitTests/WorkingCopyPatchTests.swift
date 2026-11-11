import Foundation
import GitKit
import Testing

/// Uncommitted changes saved as a patch, compared with `git diff`'s patch
/// for the same changes and applied back with `git apply`.
@Suite struct WorkingCopyPatchTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    /// A staged change, an unstaged one, a deletion, a binary file and an
    /// untracked file.
    private func makeChanges() throws {
        try fixture.commit("a.txt", "one\ntwo\nthree\n", message: "Base")
        try fixture.commit("b.txt", "bee\n", message: "Second")
        try fixture.commit("gone.txt", "going\n", message: "Third")
        try Data([0, 1, 2, 3, 255, 0]).write(to: fixture.url.appending(path: "image.bin"))
        try fixture.git("add", "image.bin")
        try fixture.git("commit", "--quiet", "-m", "Binary")

        try fixture.write("one\n2\nthree\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("bee changed\n", to: "b.txt")
        try fixture.git("rm", "--quiet", "gone.txt")
        try Data([0, 9, 8, 7, 255, 0, 1]).write(to: fixture.url.appending(path: "image.bin"))
        try fixture.write("brand new\n", to: "new.txt")
    }

    /// A patch without the data of its binary files, which git and libgit2
    /// compress differently: the same changes either way.
    private func textual(_ patch: String) -> [Substring] {
        var lines: [Substring] = []
        var isBinary = false
        for line in patch.split(separator: "\n") {
            if line.hasPrefix("diff --git") { isBinary = false }
            if !isBinary { lines.append(line) }
            if line == "GIT binary patch" { isBinary = true }
        }
        return lines
    }

    private func saved(_ patch: String) throws -> URL {
        let file = fixture.url.appendingPathExtension("patch-\(UUID().uuidString)")
        try Data(patch.utf8).write(to: file)
        return file
    }

    @Test func allChangesAreGitDiffHEAD() async throws {
        defer { fixture.remove() }
        try makeChanges()
        let repository = try fixture.open()
        let tracked = try await repository.workingCopyPatch(includingUntracked: false)
        let expected = try fixture.git("diff", "--binary", "HEAD")
        #expect(textual(tracked) == textual(expected))

        // With the untracked file, it turns the last commit into the working tree.
        let all = try saved(try await repository.workingCopyPatch())
        defer { try? FileManager.default.removeItem(at: all) }
        try fixture.git("add", "--all")
        let tree = try fixture.git("write-tree")
        try fixture.git("reset", "--quiet", "--hard")
        try fixture.git("apply", "--index", all.path)
        #expect(try fixture.git("write-tree") == tree)
    }

    @Test func stagedChangesAreGitDiffCached() async throws {
        defer { fixture.remove() }
        try makeChanges()
        let patch = try await fixture.open().workingCopyPatch(stagedOnly: true)
        let expected = try fixture.git("diff", "--binary", "--cached")
        #expect(textual(patch) == textual(expected))
        #expect(patch.contains("a.txt") && patch.contains("gone.txt") && !patch.contains("b.txt"))
    }

    @Test func chosenFilesOnly() async throws {
        defer { fixture.remove() }
        try makeChanges()
        let patch = try await fixture.open().workingCopyPatch(paths: ["b.txt", "image.bin"])
        let expected = try fixture.git("diff", "--binary", "HEAD", "--", "b.txt", "image.bin")
        #expect(textual(patch) == textual(expected))
        #expect(patch.contains("GIT binary patch"))
        // The binary data is right too: taking the patch back out restores HEAD.
        let file = try saved(patch)
        defer { try? FileManager.default.removeItem(at: file) }
        try fixture.git("apply", "-R", file.path)
        #expect(try fixture.git("diff", "--name-only", "HEAD", "--", "b.txt", "image.bin").isEmpty)
    }
}
