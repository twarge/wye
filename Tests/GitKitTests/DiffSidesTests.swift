import Foundation
import GitKit
import Testing

/// Which bytes the engine hands over for each side of a changed binary file,
/// checked against the blobs git itself names.
@Suite struct DiffSidesTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    /// A small "image": binary bytes, distinct per `seed`.
    private func image(_ seed: UInt8, count: Int = 64) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x00] + (0..<count).map { UInt8(truncatingIfNeeded: Int($0) &* 7 &+ Int(seed)) })
    }

    /// The object a revision names, through `git rev-parse`.
    private func revParse(_ revision: String) throws -> String {
        try fixture.git("rev-parse", revision).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func put(_ data: Data, at path: String) throws {
        try data.write(to: fixture.url.appending(path: path))
    }

    @Test func commitSidesAreTheParentAndCommitBlobs() async throws {
        defer { fixture.remove() }
        try put(image(1), at: "logo.png")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "-m", "Add")
        try put(image(2), at: "logo.png")
        try fixture.git("commit", "--quiet", "-am", "Change")
        let head = try #require(OID(hex: try revParse("HEAD")))

        let repository = try fixture.open()
        let file = try #require(try await repository.changes(in: head).first)
        #expect(file.isBinary)
        let oldBlob = try revParse("HEAD~1:logo.png")
        let newBlob = try revParse("HEAD:logo.png")
        #expect(file.oldBlobID?.hex == oldBlob)
        #expect(file.newBlobID?.hex == newBlob)
        let sides = try await repository.sides(of: file)
        #expect(sides.old?.data == image(1))
        #expect(sides.new?.data == image(2))
        #expect(sides.new?.size == image(2).count)
    }

    @Test func addedAndDeletedFilesHaveOneSide() async throws {
        defer { fixture.remove() }
        try put(image(1), at: "a.png")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "-m", "Add")
        let added = try #require(OID(hex: try revParse("HEAD")))
        try fixture.git("rm", "--quiet", "a.png")
        try fixture.git("commit", "--quiet", "-m", "Remove")
        let removed = try #require(OID(hex: try revParse("HEAD")))

        let repository = try fixture.open()
        let addition = try #require(try await repository.changes(in: added).first)
        let additionSides = try await repository.sides(of: addition)
        #expect(additionSides.old == nil)
        #expect(additionSides.new?.data == image(1))

        let deletion = try #require(try await repository.changes(in: removed).first)
        #expect(deletion.change == .deleted)
        let deletionSides = try await repository.sides(of: deletion)
        #expect(deletionSides.old?.data == image(1))
        #expect(deletionSides.new == nil)
    }

    @Test func stagedSidesAreHeadAndIndex() async throws {
        defer { fixture.remove() }
        try put(image(1), at: "a.png")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "-m", "Add")
        try put(image(2), at: "a.png")
        try fixture.git("add", "a.png")
        // The working tree moves on again; the staged side must not see it.
        try put(image(3), at: "a.png")

        let repository = try fixture.open()
        let staged = try #require(try await repository.stagedDiff(of: "a.png"))
        #expect(!staged.newSideIsWorkingTree)
        let stagedSides = try await repository.sides(of: staged)
        #expect(stagedSides.old?.data == image(1))
        #expect(stagedSides.new?.data == image(2))

        let unstaged = try #require(try await repository.unstagedDiff(of: "a.png"))
        #expect(unstaged.newSideIsWorkingTree)
        let unstagedSides = try await repository.sides(of: unstaged)
        #expect(unstagedSides.old?.data == image(2))
        #expect(unstagedSides.new?.data == image(3))
    }

    @Test func untrackedFileIsReadFromTheWorkingTree() async throws {
        defer { fixture.remove() }
        try fixture.commit("README", "hello\n", message: "Start")
        try put(image(4), at: "new.png")

        let repository = try fixture.open()
        let file = try #require(try await repository.unstagedDiff(of: "new.png"))
        let sides = try await repository.sides(of: file)
        #expect(sides.old == nil)
        #expect(sides.new?.data == image(4))
    }

    @Test func workingTreeComparisonReadsTheFileOnDisk() async throws {
        defer { fixture.remove() }
        try put(image(1), at: "a.png")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "-m", "Add")
        try put(image(5), at: "a.png")

        let repository = try fixture.open()
        let file = try #require(try await repository.changes(in: .workingTreeToHead).first)
        let sides = try await repository.sides(of: file)
        #expect(sides.old?.data == image(1))
        #expect(sides.new?.data == image(5))
    }

    @Test func sidesOverTheLimitAreMeasuredNotRead() async throws {
        defer { fixture.remove() }
        try put(image(1, count: 4_000), at: "a.png")
        try fixture.git("add", ".")
        try fixture.git("commit", "--quiet", "-m", "Add")
        try put(image(2, count: 4_000), at: "a.png")

        let repository = try fixture.open()
        let file = try #require(try await repository.unstagedDiff(of: "a.png"))
        let sides = try await repository.sides(of: file, limit: 1_000)
        #expect(sides.old?.size == image(1, count: 4_000).count)
        #expect(sides.old?.data == nil)
        #expect(sides.new?.size == image(2, count: 4_000).count)
        #expect(sides.new?.data == nil)
    }
}
