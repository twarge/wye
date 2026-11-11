import Foundation
import GitKit
import Testing

/// The working tree, the index and `HEAD` compared as a whole, against
/// `git diff HEAD`, `git diff` and `git diff --cached`.
@Suite struct WorkingTreeCompareTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
        try fixture.commit("a.txt", "one\ntwo\nthree\n", message: "First")
        try fixture.commit("b.txt", "bee\n", message: "Second")
        try fixture.commit("gone.txt", "going\n", message: "Third")
        // Staged only, staged then changed again, unstaged only, a staged
        // new file, a deletion, and an untracked file git leaves out.
        try fixture.write("one\nTWO\nthree\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("one\nTWO\nthree\nfour\n", to: "a.txt")
        try fixture.write("bee edited\n", to: "b.txt")
        try fixture.write("added\n", to: "c.txt")
        try fixture.git("add", "c.txt")
        try fixture.git("rm", "--quiet", "gone.txt")
        try fixture.write("untracked\n", to: "untracked.txt")
    }

    /// git's list of changed paths with their status letters.
    private func gitNames(_ arguments: String...) throws -> [String] {
        try fixture.git(["diff", "--name-status", "--no-renames"] + arguments)
            .split(separator: "\n").map { $0.replacingOccurrences(of: "\t", with: " ") }
    }

    private func names(_ files: [FileDiff]) -> [String] {
        files.map { file in
            let letter = switch file.change {
            case .added: "A"
            case .deleted: "D"
            default: "M"
            }
            return "\(letter) \(file.path)"
        }
    }

    @Test(arguments: WorkingTreeComparison.allCases)
    func listsWhatGitDiffLists(_ comparison: WorkingTreeComparison) async throws {
        defer { fixture.remove() }
        let files = try await fixture.open().changes(in: comparison)
        let expected = switch comparison {
        case .workingTreeToHead: try gitNames("HEAD")
        case .workingTreeToIndex: try gitNames()
        case .indexToHead: try gitNames("--cached")
        }
        #expect(names(files) == expected)
    }

    @Test func linesMatchGit() async throws {
        defer { fixture.remove() }
        let repository = try fixture.open()
        let head = try #require(try await repository.changes(in: .workingTreeToHead).first { $0.path == "a.txt" })
        let index = try #require(try await repository.changes(in: .workingTreeToIndex).first { $0.path == "a.txt" })
        let staged = try #require(try await repository.changes(in: .indexToHead).first { $0.path == "a.txt" })
        #expect((head.additions, head.deletions) == (2, 1))
        #expect((index.additions, index.deletions) == (1, 0))
        #expect((staged.additions, staged.deletions) == (1, 1))
    }
}

extension Fixture {
    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        try Self.run(arguments, in: url)
    }
}
