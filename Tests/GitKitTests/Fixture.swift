import Foundation
import GitKit

/// A scratch repository built with the command line git, so the tests check
/// GitKit against git itself rather than against its own writes.
struct Fixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "GitKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "--quiet", "--initial-branch=main")
        try git("config", "user.name", "Test Author")
        try git("config", "user.email", "author@example.com")
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func open() throws -> Repository {
        try Repository(at: url)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try Self.run(arguments, in: url)
    }

    func write(_ text: String, to path: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Writes a file and commits it, returning the new commit's name.
    @discardableResult
    func commit(_ path: String, _ text: String, message: String) throws -> String {
        try write(text, to: path)
        try git("add", path)
        try git("commit", "--quiet", "-m", message)
        return try git("rev-parse", "HEAD")
    }

    /// Runs git with posix_spawn rather than `Process`: the tests launch git
    /// hundreds of times, and this is several times faster.
    static func run(_ arguments: [String], in directory: URL) throws -> String {
        // The same on every machine, whatever the developer's own git setup.
        let environment = [
            "GIT_CONFIG_GLOBAL=/dev/null",
            "GIT_CONFIG_NOSYSTEM=1",
            "GIT_AUTHOR_DATE=2026-01-02T03:04:05+01:00",
            "GIT_COMMITTER_DATE=2026-01-02T03:04:05+01:00",
            "PATH=/usr/bin:/bin"
        ]
        let output = directory.appendingPathExtension("output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir(&actions, directory.path)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        var argumentPointers = (["git"] + arguments).map { strdup($0) } + [nil]
        var environmentPointers = environment.map { strdup($0) } + [nil]
        defer { (argumentPointers + environmentPointers).forEach { free($0) } }

        var process = pid_t()
        guard posix_spawn(&process, "/usr/bin/git", &actions, nil, &argumentPointers, &environmentPointers) == 0 else {
            throw FixtureError(message: "Could not launch git.")
        }
        var status: Int32 = 0
        while waitpid(process, &status, 0) == -1, errno == EINTR {}

        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        guard status == 0 else {
            throw FixtureError(message: "git \(arguments.joined(separator: " ")) failed: \(text)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}
