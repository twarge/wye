import Foundation
import GitKit
import Testing

@Suite struct IgnoreTests {
    let fixture: Fixture

    init() throws {
        fixture = try Fixture()
    }

    @Test func findsIgnoredPathsThatHoldNothingTracked() async throws {
        defer { fixture.remove() }
        try fixture.commit(".gitignore", "build/\n*.o\nout/\n", message: "Ignore")
        try fixture.write("kept\n", to: "build/keep.txt")
        try fixture.git("add", "--force", "build/keep.txt")
        try fixture.git("commit", "--quiet", "-m", "Keep one built file")
        try fixture.write("x", to: "build/product.bin")
        try fixture.write("x", to: "src/main.o")
        try fixture.write("x", to: "src/main.c")
        try fixture.write("x", to: "out/a/b.txt")
        try fixture.write("x", to: "tracked.o")
        try fixture.git("add", "--force", "tracked.o")

        let paths = [
            "build", "build/keep.txt", "build/product.bin", "src", "src/main.o", "src/main.c",
            "out", "out/a/b.txt", "tracked.o", "missing.o", ".gitignore"
        ]
        let ignored = try await fixture.open().ignoredUntrackedPaths(among: paths)

        // git's own list of ignored files that are not tracked.
        let untrackedIgnored = Set(try fixture.git("ls-files", "--others", "--ignored", "--exclude-standard")
            .split(separator: "\n").map(String.init))
        for path in paths where FileManager.default.fileExists(atPath: fixture.url.appending(path: path).path)
            && !path.hasPrefix("out") && path != "build" && path != "src" {
            #expect(ignored.contains(path) == untrackedIgnored.contains(path), "\(path)")
        }
        // A folder counts only when nothing inside it is tracked.
        #expect(!ignored.contains("build"))
        #expect(ignored.contains("out"))
        #expect(ignored.contains("out/a/b.txt"))
        #expect(!ignored.contains("src"))
        // A path that is not there is judged by the rules alone.
        #expect(ignored.contains("missing.o"))
    }
}
