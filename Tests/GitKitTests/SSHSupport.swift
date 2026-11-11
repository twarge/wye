import Foundation
import GitKit

/// Runs a program with posix_spawn, as `Fixture.run` runs git, with a home
/// folder of its own so that nothing reads or writes the user's `~/.ssh`.
@discardableResult
func runTool(
    _ path: String, _ arguments: [String], in directory: URL, home: URL? = nil, allowFailure: Bool = false
) throws -> String {
    let environment = [
        "HOME=\((home ?? directory).path)",
        "GIT_CONFIG_GLOBAL=/dev/null",
        "GIT_CONFIG_NOSYSTEM=1",
        "GIT_AUTHOR_DATE=2026-01-02T03:04:05+01:00",
        "GIT_COMMITTER_DATE=2026-01-02T03:04:05+01:00",
        "SSH_AUTH_SOCK=",
        "PATH=/usr/bin:/bin"
    ]
    let output = directory.appending(path: "output-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: output) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addchdir(&actions, directory.path)
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

    var argumentPointers = ([path] + arguments).map { strdup($0) } + [nil]
    var environmentPointers = environment.map { strdup($0) } + [nil]
    defer { (argumentPointers + environmentPointers).forEach { free($0) } }

    var process = pid_t()
    guard posix_spawn(&process, path, &actions, nil, &argumentPointers, &environmentPointers) == 0 else {
        throw FixtureError(message: "Could not launch \(path).")
    }
    var status: Int32 = 0
    while waitpid(process, &status, 0) == -1, errno == EINTR {}
    let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    guard status == 0 || allowFailure else {
        throw FixtureError(message: "\(path) \(arguments.joined(separator: " ")) failed: \(text)")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A scratch folder for key files.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "GitKitSSH-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Makes a key with ssh-keygen and returns its private key file's text.
    @discardableResult
    func keygen(_ name: String, _ options: [String], passphrase: String = "", comment: String = "test key") throws -> String {
        try runTool(
            "/usr/bin/ssh-keygen", ["-q"] + options + ["-N", passphrase, "-C", comment, "-f", name], in: url
        )
        return try String(contentsOf: url.appending(path: name), encoding: .utf8)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: url.appending(path: name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ssh-keygen's `SHA256:…` fingerprint for a key file.
    func fingerprint(_ name: String) throws -> String {
        let line = try runTool("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", name], in: url)
        return String(line.split(separator: " ")[1])
    }
}

/// Credentials for tests: fixed keys and a known-hosts file of their own.
struct TestCredentials: CredentialProvider {
    var keys: [SSHPrivateKey]
    var knownHosts: KnownHosts

    func credential(for request: CredentialRequest) -> Credential? { nil }

    func sshKeys(for request: SSHKeyRequest) -> [SSHPrivateKey] { keys }

    func trust(for hostKey: SSHHostKey) -> SSHHostKeyTrust {
        knownHosts.trust(for: hostKey)
    }
}

/// Bytes that do not compress, made quickly.
func randomData(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        let words = buffer.bindMemory(to: UInt64.self)
        for index in words.indices {
            words[index] = generator.next()
        }
    }
    return data
}
