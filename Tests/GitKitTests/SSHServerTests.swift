import Foundation
import GitKit
import Testing

/// An OpenSSH server run by the test, as the current user, on a free port
/// of 127.0.0.1, with a host key and an authorized client key of its own.
/// It never sees the user's keys, agent or `~/.ssh`.
final class LocalSSHServer: @unchecked Sendable {
    static let sshd = "/usr/sbin/sshd"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: sshd) }

    let folder: TemporaryFolder
    private(set) var port: Int
    let user: String
    /// The key the server presents, and the one it lets in.
    let hostKey: SSHPublicKey
    let clientKey: SSHPrivateKey
    private var process = pid_t()

    init() throws {
        folder = try TemporaryFolder()
        let url = folder.url
        try folder.keygen("host_key", ["-t", "ed25519"], comment: "host")
        let client = try folder.keygen("client_key", ["-t", "ed25519"], comment: "client")
        clientKey = try SSHPrivateKey(openSSHPrivateKey: client)
        hostKey = try SSHPublicKey(openSSH: try folder.read("host_key.pub"))
        try FileManager.default.copyItem(at: url.appending(path: "client_key.pub"), to: url.appending(path: "authorized_keys"))
        user = NSUserName()
        port = 0
        // A free port can be taken by another test's connection before sshd
        // binds it; then try another.
        for attempt in 1...5 {
            port = try Self.freePort()
            do {
                try start()
                return
            } catch is FixtureError where attempt < 5 && log.contains("Address already in use") {
                continue
            }
        }
        throw FixtureError(message: "sshd found no free port.")
    }

    private func start() throws {
        let url = folder.url
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(url.path)/host_key
        AuthorizedKeysFile \(url.path)/authorized_keys
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        UsePAM no
        StrictModes no
        PidFile \(url.path)/sshd.pid
        SetEnv GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
        """.write(to: url.appending(path: "sshd_config"), atomically: true, encoding: .utf8)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(
            &actions, STDERR_FILENO, url.appending(path: "sshd.log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o600
        )
        posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDOUT_FILENO)
        var arguments = ([Self.sshd, "-D", "-e", "-f", url.appending(path: "sshd_config").path] as [String])
            .map { strdup($0) } + [nil]
        var environment = (["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(url.path)"] as [String])
            .map { strdup($0) } + [nil]
        defer { (arguments + environment).forEach { free($0) } }
        guard posix_spawn(&process, Self.sshd, &actions, nil, &arguments, &environment) == 0 else {
            throw FixtureError(message: "Could not launch sshd.")
        }
        try waitUntilListening()
    }

    deinit {
        stop()
    }

    func stop() {
        guard process != 0 else { return }
        kill(process, SIGTERM)
        var status: Int32 = 0
        while waitpid(process, &status, 0) == -1, errno == EINTR {}
        process = 0
        folder.remove()
    }

    var log: String { (try? folder.read("sshd.log")) ?? "" }

    /// The server's key as Twig would be shown it.
    var presentedHostKey: SSHHostKey {
        SSHHostKey(host: "127.0.0.1", port: port, publicKey: hostKey)
    }

    func url(_ path: URL) -> String {
        "ssh://\(user)@127.0.0.1:\(port)\(path.path)"
    }

    private static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(socket, address, length) == 0 && getsockname(socket, address, &length) == 0
            }
        }
        guard bound else { throw FixtureError(message: "No free port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func waitUntilListening() throws {
        for _ in 0..<100 {
            var status: Int32 = 0
            if waitpid(process, &status, WNOHANG) == process {
                process = 0
                throw FixtureError(message: "sshd stopped: \(log)")
            }
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = UInt16(port).bigEndian
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(socket)
            if connected { return }
            usleep(50_000)
        }
        throw FixtureError(message: "sshd did not start listening: \(log)")
    }
}

/// GitKit over SSH to a real OpenSSH server on this machine, checked with
/// the command line git on the server's side.
@Suite(.enabled(if: LocalSSHServer.isAvailable, "This machine has no /usr/sbin/sshd to test against."))
struct SSHServerTests {
    let server: LocalSSHServer
    let work: TemporaryFolder
    /// The bare repository the server serves, and a clone on disk of it
    /// standing for someone else.
    let remote: URL
    let knownHosts: KnownHosts

    init() throws {
        server = try LocalSSHServer()
        work = try TemporaryFolder()
        remote = work.url.appending(path: "remote.git")
        knownHosts = KnownHosts(file: work.url.appending(path: "known_hosts"), includeBuiltIn: false)
        let seed = work.url.appending(path: "seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try git(["init", "--quiet", "--initial-branch=main"], in: seed)
        try "one\n".write(to: seed.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"], in: seed)
        try git(["-c", "user.name=Seed", "-c", "user.email=seed@example.com", "commit", "--quiet", "-m", "First"], in: seed)
        try git(["clone", "--quiet", "--bare", seed.path, remote.path], in: work.url)
    }

    private func finish() {
        server.stop()
        work.remove()
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        try runTool("/usr/bin/git", arguments, in: directory, home: work.url)
    }

    private func credentials(_ keys: [SSHPrivateKey]? = nil) -> TestCredentials {
        TestCredentials(keys: keys ?? [server.clientKey], knownHosts: knownHosts)
    }

    private func trustServer() throws {
        try knownHosts.trust(server.presentedHostKey)
    }

    private func clone(into name: String, credentials: TestCredentials? = nil, url: String? = nil) async throws -> Repository {
        try await Repository.clone(
            from: url ?? server.url(remote), to: work.url.appending(path: name),
            credentials: credentials ?? self.credentials()
        )
    }

    // MARK: Host keys

    @Test func anUnknownHostKeyIsRefusedThenWorksOnceTrusted() async throws {
        defer { finish() }
        await #expect(throws: RemoteError.unknownHostKey(server.presentedHostKey)) {
            _ = try await clone(into: "refused")
        }
        #expect(!FileManager.default.fileExists(atPath: work.url.appending(path: "refused").path))
        // The fingerprint shown is the one ssh-keygen gives for the server's key.
        #expect(server.presentedHostKey.fingerprint == (try server.folder.fingerprint("host_key.pub")))

        try trustServer()
        _ = try await clone(into: "trusted")
        #expect(try git(["rev-parse", "HEAD"], in: work.url.appending(path: "trusted"))
                == (try git(["rev-parse", "main"], in: remote)))
    }

    @Test func aChangedHostKeyIsAMismatch() async throws {
        defer { finish() }
        let other = SSHPrivateKey.generateEd25519(comment: "").publicKey
        try knownHosts.trust(SSHHostKey(host: "127.0.0.1", port: server.port, publicKey: other))
        await #expect(throws: RemoteError.hostKeyChanged(server.presentedHostKey, known: other)) {
            _ = try await clone(into: "mismatch")
        }
    }

    // MARK: Logging in

    @Test func aKeyTheServerDoesNotKnowIsRejected() async throws {
        defer { finish() }
        try trustServer()
        let user = server.user
        await #expect(throws: RemoteError.sshKeysRejected(host: "127.0.0.1", username: user)) {
            _ = try await clone(into: "wrong", credentials: credentials([.generateEd25519(comment: "stranger")]))
        }
        await #expect(throws: RemoteError.sshKeyRequired(host: "127.0.0.1", username: user)) {
            _ = try await clone(into: "none", credentials: credentials([]))
        }
        // A key the server does not know, then one it does: the second gets in.
        _ = try await clone(into: "second", credentials: credentials([.generateEd25519(comment: ""), server.clientKey]))
    }

    @Test func whatTheServerSaysIsTheError() async throws {
        defer { finish() }
        try trustServer()
        let missing = work.url.appending(path: "missing.git")
        await #expect {
            _ = try await clone(into: "missing", url: server.url(missing))
        } throws: { error in
            guard case RemoteError.remoteCommandFailed(_, let message) = error else { return false }
            return message.contains("does not appear to be a git repository")
        }
    }

    // MARK: Fetch, pull, push

    @Test func clonesFetchesPullsAndPushes() async throws {
        defer { finish() }
        try trustServer()
        let repository = try await clone(into: "local")
        let local = work.url.appending(path: "local")
        try git(["config", "user.name", "Local"], in: local)
        try git(["config", "user.email", "local@example.com"], in: local)

        // Someone else pushes a commit to the server's repository.
        let other = work.url.appending(path: "other")
        try git(["clone", "--quiet", remote.path, other.path], in: work.url)
        try "two\n".write(to: other.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "b.txt"], in: other)
        try git(["-c", "user.name=O", "-c", "user.email=o@example.com", "commit", "--quiet", "-m", "Second"], in: other)
        try git(["push", "--quiet", "origin", "main"], in: other)
        let theirs = try git(["rev-parse", "HEAD"], in: other)

        try await repository.fetch(credentials: credentials())
        #expect(try git(["rev-parse", "origin/main"], in: local) == theirs)

        let pulled = try await repository.pull(credentials: credentials())
        #expect(pulled == .fastForwarded(to: OID(hex: theirs)!))
        #expect(try git(["rev-parse", "HEAD"], in: local) == theirs)

        try "three\n".write(to: local.appending(path: "c.txt"), atomically: true, encoding: .utf8)
        try git(["add", "c.txt"], in: local)
        try git(["commit", "--quiet", "-m", "Third"], in: local)
        let ours = try git(["rev-parse", "HEAD"], in: local)
        let pushed = try await repository.push(credentials: credentials())
        #expect(pushed.reference == "refs/heads/main")
        #expect(try git(["rev-parse", "main"], in: remote) == ours)
    }

    @Test func scpLikeAddressesWork() async throws {
        defer { finish() }
        try trustServer()
        _ = try await clone(into: "scp", url: "\(server.user)@[127.0.0.1:\(server.port)]:\(remote.path)")
        #expect(try git(["rev-parse", "HEAD"], in: work.url.appending(path: "scp"))
                == (try git(["rev-parse", "main"], in: remote)))
    }

    /// A push of several megabytes of data that does not compress, more than
    /// the SSH window holds, arrives intact.
    @Test func aPushBiggerThanTheWindowArrivesIntact() async throws {
        defer { finish() }
        try trustServer()
        let repository = try await clone(into: "big")
        let local = work.url.appending(path: "big")
        for index in 0..<3 {
            try randomData(count: 3 << 20).write(to: local.appending(path: "random-\(index).bin"))
        }
        try git(["add", "."], in: local)
        try git(["-c", "user.name=L", "-c", "user.email=l@example.com", "commit", "--quiet", "-m", "Big"], in: local)
        let ours = try git(["rev-parse", "HEAD"], in: local)

        try await repository.push(credentials: credentials())
        #expect(try git(["rev-parse", "main"], in: remote) == ours)
        try git(["fsck", "--full", "--strict"], in: remote)
        #expect(try git(["rev-parse", "main:random-2.bin"], in: remote)
                == (try git(["rev-parse", "HEAD:random-2.bin"], in: local)))

        // And back again: a fresh clone of it over SSH.
        _ = try await clone(into: "big-again")
        let again = work.url.appending(path: "big-again")
        #expect(try git(["rev-parse", "HEAD"], in: again) == ours)
        #expect(try Data(contentsOf: again.appending(path: "random-1.bin"))
                == (try Data(contentsOf: local.appending(path: "random-1.bin"))))
        try git(["fsck", "--full"], in: again)
    }

    @Test func aCloneCanBeCancelledPartWay() async throws {
        defer { finish() }
        try trustServer()
        // Enough that the transfer is still going when it is cancelled.
        let seed = work.url.appending(path: "large-seed")
        try git(["clone", "--quiet", remote.path, seed.path], in: work.url)
        for index in 0..<48 {
            try randomData(count: 512 << 10).write(to: seed.appending(path: "blob-\(index).bin"))
        }
        try git(["add", "."], in: seed)
        try git(["-c", "user.name=S", "-c", "user.email=s@example.com", "commit", "--quiet", "-m", "Large"], in: seed)
        try git(["push", "--quiet", "origin", "main"], in: seed)

        let transfer = Transfer()
        let destination = work.url.appending(path: "cancelled")
        let watcher = Task(priority: .high) {
            for await progress in transfer.progress where progress.phase == .receivingObjects && progress.completed < progress.total {
                transfer.cancel()
                return ContinuousClock.now as ContinuousClock.Instant?
            }
            return nil
        }
        await #expect(throws: CancellationError.self) {
            _ = try await Repository.clone(
                from: server.url(remote), to: destination, credentials: credentials(), transfer: transfer
            )
        }
        let cancelledAt = try #require(await watcher.value)
        // It stops soon after, not at the end of the transfer.
        #expect(ContinuousClock.now - cancelledAt < .seconds(5))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: ".git").path))
    }
}
