import Foundation
@testable import GitKit
import Testing

/// Keys made by ssh-keygen, read by GitKit, and the public keys and
/// fingerprints GitKit gives for them compared with ssh-keygen's.
@Suite struct SSHKeyTests {
    let folder: TemporaryFolder

    init() throws {
        folder = try TemporaryFolder()
    }

    static let kinds: [(options: [String], kind: SSHKeyKind)] = [
        (["-t", "ed25519"], .ed25519),
        (["-t", "ecdsa", "-b", "256"], .ecdsaP256),
        (["-t", "ecdsa", "-b", "384"], .ecdsaP384),
        (["-t", "ecdsa", "-b", "521"], .ecdsaP521)
    ]

    @Test(arguments: 0..<4)
    func importsUnencryptedKeys(_ index: Int) throws {
        defer { folder.remove() }
        let (options, kind) = Self.kinds[index]
        let text = try folder.keygen("key", options, comment: "me@example")
        #expect(try SSHPrivateKey.isEncrypted(openSSHPrivateKey: text) == false)
        let key = try SSHPrivateKey(openSSHPrivateKey: text)
        #expect(key.kind == kind)
        #expect(key.comment == "me@example")
        #expect(key.openSSHPublicKey == (try folder.read("key.pub")))
        #expect(key.publicKey.openSSH + " me@example"
                == (try runTool("/usr/bin/ssh-keygen", ["-y", "-f", "key"], in: folder.url)))
        #expect(key.publicKey.fingerprint == (try folder.fingerprint("key.pub")))
    }

    @Test(arguments: 0..<4)
    func importsPassphraseProtectedKeys(_ index: Int) throws {
        defer { folder.remove() }
        let (options, kind) = Self.kinds[index]
        // Few rounds keep the test quick; the default is 16.
        let text = try folder.keygen("key", options + ["-a", "4"], passphrase: "correct horse")
        #expect(try SSHPrivateKey.isEncrypted(openSSHPrivateKey: text))
        #expect(throws: SSHKeyError.passphraseRequired) { try SSHPrivateKey(openSSHPrivateKey: text) }
        #expect(throws: SSHKeyError.wrongPassphrase) {
            try SSHPrivateKey(openSSHPrivateKey: text, passphrase: "wrong horse")
        }
        let key = try SSHPrivateKey(openSSHPrivateKey: text, passphrase: "correct horse")
        #expect(key.kind == kind)
        #expect(key.publicKey.fingerprint == (try folder.fingerprint("key.pub")))
    }

    @Test func importsAKeyWithTheDefaultRoundsAndGCMCipher() throws {
        defer { folder.remove() }
        let ctr = try folder.keygen("ctr", ["-t", "ed25519"], passphrase: "secret")
        #expect(try SSHPrivateKey(openSSHPrivateKey: ctr, passphrase: "secret").publicKey.fingerprint
                == (try folder.fingerprint("ctr.pub")))
        let gcm = try folder.keygen("gcm", ["-t", "ed25519", "-a", "2", "-Z", "aes256-gcm@openssh.com"], passphrase: "secret")
        #expect(try SSHPrivateKey(openSSHPrivateKey: gcm, passphrase: "secret").publicKey.fingerprint
                == (try folder.fingerprint("gcm.pub")))
        #expect(throws: SSHKeyError.wrongPassphrase) { try SSHPrivateKey(openSSHPrivateKey: gcm, passphrase: "nope") }
    }

    @Test func importsAnECDSAKeyInTheOlderPEMFormat() throws {
        defer { folder.remove() }
        let text = try folder.keygen("key", ["-t", "ecdsa", "-b", "384", "-m", "PEM"])
        #expect(text.hasPrefix("-----BEGIN EC PRIVATE KEY-----"))
        let key = try SSHPrivateKey(openSSHPrivateKey: text)
        #expect(key.kind == .ecdsaP384)
        #expect(key.publicKey.fingerprint == (try folder.fingerprint("key.pub")))
    }

    @Test func rsaKeysAreRecognisedAndRefused() throws {
        defer { folder.remove() }
        let plain = try folder.keygen("plain", ["-t", "rsa", "-b", "2048"])
        #expect(throws: SSHKeyError.rsaNotSupported) { try SSHPrivateKey(openSSHPrivateKey: plain) }
        // Known before any passphrase is asked for.
        let encrypted = try folder.keygen("encrypted", ["-t", "rsa", "-b", "2048", "-a", "2"], passphrase: "secret")
        #expect(throws: SSHKeyError.rsaNotSupported) { try SSHPrivateKey(openSSHPrivateKey: encrypted) }
        let pem = try folder.keygen("pem", ["-t", "rsa", "-b", "2048", "-m", "PEM"])
        #expect(throws: SSHKeyError.rsaNotSupported) { try SSHPrivateKey(openSSHPrivateKey: pem) }
    }

    @Test func refusesWhatIsNotAKey() {
        defer { folder.remove() }
        #expect(throws: SSHKeyError.invalidFormat) { try SSHPrivateKey(openSSHPrivateKey: "hello") }
        #expect(throws: SSHKeyError.invalidFormat) {
            try SSHPrivateKey(openSSHPrivateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----")
        }
    }

    @Test func generatedKeysAreWhatSSHKeygenReads() throws {
        defer { folder.remove() }
        let key = SSHPrivateKey.generateEd25519(comment: "twig@example")
        #expect(key.openSSHPublicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        #expect(key.openSSHPublicKey.hasSuffix(" twig@example"))
        try key.openSSHPublicKey.write(to: folder.url.appending(path: "generated.pub"), atomically: true, encoding: .utf8)
        #expect(key.publicKey.fingerprint == (try folder.fingerprint("generated.pub")))
        #expect(SSHPrivateKey.generateEd25519(comment: "") != key)
    }

    @Test func aKeysDescriptionDoesNotShowTheSecret() throws {
        defer { folder.remove() }
        let key = SSHPrivateKey.generateEd25519(comment: "")
        let secret = key.rawRepresentation.base64EncodedString()
        #expect(!String(describing: key).contains(secret))
        #expect(!String(reflecting: key).contains(secret))
        #expect(String(describing: key).contains(key.publicKey.fingerprint))
    }

    @Test func publicKeyLinesRoundTrip() throws {
        defer { folder.remove() }
        let key = SSHPrivateKey.generateEd25519(comment: "x")
        let parsed = try SSHPublicKey(openSSH: key.openSSHPublicKey)
        #expect(parsed == key.publicKey)
        #expect(parsed.kind == .ed25519)
        #expect(throws: SSHKeyError.invalidFormat) { try SSHPublicKey(openSSH: "ssh-rsa " + parsed.blob.base64EncodedString()) }
    }

    /// The fingerprints the hosting services publish, for the keys Twig
    /// trusts from the start.
    @Test func builtInHostKeysMatchTheirPublishedFingerprints() {
        defer { folder.remove() }
        let fingerprints = Dictionary(
            KnownHosts.builtIn.map { ("\($0.pattern) \($0.publicKey.algorithm)", $0.publicKey.fingerprint) }
        ) { first, _ in first }
        #expect(fingerprints == [
            "github.com ssh-ed25519": "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
            "github.com ecdsa-sha2-nistp256": "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
            "gitlab.com ssh-ed25519": "SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8",
            "gitlab.com ecdsa-sha2-nistp256": "SHA256:HbW3g8zUjNSksFbqTiUWPWg2Bq1x8xdGUrliXFzSnUw",
            "bitbucket.org ssh-ed25519": "SHA256:ybgmFkzwOSotHTHLJgHO0QN8L0xErw6vd0VhFA9m3SM",
            "bitbucket.org ecdsa-sha2-nistp256": "SHA256:FC73VB6C4OQLSCrjEayhMp9UMxS97caD/Yyi2bhW/J0"
        ])
    }
}

/// SSH addresses read as git reads them, and the command sent for them.
@Suite struct SSHAddressTests {
    @Test func readsSSHURLs() throws {
        #expect(try SSHAddress("ssh://git@example.com/owner/project.git")
                == SSHAddress(username: "git", host: "example.com", port: 22, path: "/owner/project.git"))
        #expect(try SSHAddress("ssh://example.com:2222/srv/project.git")
                == SSHAddress(username: nil, host: "example.com", port: 2222, path: "/srv/project.git"))
        #expect(try SSHAddress("ssh+git://me@example.com:2200/x")
                == SSHAddress(username: "me", host: "example.com", port: 2200, path: "/x"))
        #expect(try SSHAddress("git+ssh://example.com/x").host == "example.com")
        #expect(try SSHAddress("SSH://[::1]:2222/repo").host == "::1")
        #expect(try SSHAddress("SSH://[::1]:2222/repo").port == 2222)
        #expect(try SSHAddress("ssh://first.last%40corp@example.com/x").username == "first.last@corp")
        // A path under a home folder, as git reads it.
        #expect(try SSHAddress("ssh://example.com/~me/project.git").path == "~me/project.git")
        #expect(try SSHAddress("ssh://example.com/~/project.git").path == "~/project.git")
    }

    @Test func readsSCPLikeAddresses() throws {
        #expect(try SSHAddress("git@github.com:owner/project.git")
                == SSHAddress(username: "git", host: "github.com", port: 22, path: "owner/project.git"))
        #expect(try SSHAddress("example.com:/srv/project.git")
                == SSHAddress(username: nil, host: "example.com", port: 22, path: "/srv/project.git"))
        #expect(try SSHAddress("me@[example.com:2222]:project.git")
                == SSHAddress(username: "me", host: "example.com", port: 2222, path: "project.git"))
        #expect(try SSHAddress("[::1]:repo.git") == SSHAddress(username: nil, host: "::1", port: 22, path: "repo.git"))
        #expect(try SSHAddress("host:~/project.git").path == "~/project.git")
    }

    @Test func refusesWhatIsNotAnSSHAddress() {
        for url in ["https://example.com/x", "ssh://", "ssh://example.com", "ssh://example.com:port/x",
                    "ssh://example.com:99999/x", "host:", "/local/path:x", "relative/path"] {
            #expect(throws: RemoteError.self, "\(url)") { try SSHAddress(url) }
        }
    }

    @Test func defaultsTheUserNameToGit() throws {
        #expect(try SSHAddress("example.com:x").loginName == "git")
        #expect(try SSHAddress("me@example.com:x").loginName == "me")
    }

    @Test func quotesThePathAsGitDoes() throws {
        #expect(try SSHAddress("ssh://h/srv/my project.git").command("git-upload-pack")
                == "git-upload-pack '/srv/my project.git'")
        #expect(try SSHAddress("h:it's.git").command("git-receive-pack") == "git-receive-pack 'it'\\''s.git'")
        #expect(SSHAddress.quote("wow!") == "'wow'\\!''")
        #expect(SSHAddress.quote("$(rm -rf /) `x` \"y\"") == "'$(rm -rf /) `x` \"y\"'")
        #expect(try SSHAddress("h:~/x").command("git-upload-pack") == "git-upload-pack '~/x'")
    }

    @Test func recognisesSSHRemotes() {
        #expect(SSHAddress.isSSH("git@github.com:o/p.git"))
        #expect(SSHAddress.isSSH("ssh://h/x"))
        #expect(SSHAddress.isSSH("git+ssh://h/x"))
        #expect(!SSHAddress.isSSH("https://h/x"))
        #expect(!SSHAddress.isSSH("/local/path"))
        #expect(!SSHAddress.isSSH("./a:b"))
    }
}

/// Trusted host keys kept in a known_hosts file.
@Suite struct KnownHostsTests {
    let folder: TemporaryFolder

    init() throws {
        folder = try TemporaryFolder()
    }

    private func hostKey(_ host: String, port: Int = 22, _ key: SSHPrivateKey = .generateEd25519(comment: "")) -> SSHHostKey {
        SSHHostKey(host: host, port: port, publicKey: key.publicKey)
    }

    @Test func unknownThenTrustedThenMismatched() throws {
        defer { folder.remove() }
        let store = KnownHosts(file: folder.url.appending(path: "Twig/known_hosts"), includeBuiltIn: false)
        let key = hostKey("Example.com", port: 2222)
        #expect(store.trust(for: key) == .unknown)
        try store.trust(key)
        #expect(store.trust(for: key) == .trusted)
        #expect(try folder.read("Twig/known_hosts") == "[example.com]:2222 \(key.openSSH)")
        // The same host on another port is another host.
        #expect(store.trust(for: SSHHostKey(host: "example.com", port: 22, publicKey: key.publicKey)) == .unknown)

        let replaced = hostKey("example.com", port: 2222)
        #expect(store.trust(for: replaced) == .mismatch(known: key.publicKey))
        // A key of another type is new, not a change.
        let ecdsa = try SSHPrivateKey(kind: .ecdsaP256, rawRepresentation: Data(repeating: 7, count: 32))
        #expect(store.trust(for: hostKey("example.com", port: 2222, ecdsa)) == .unknown)

        // Trusting the new key replaces the old one of its type.
        try store.trust(replaced)
        #expect(store.trust(for: replaced) == .trusted)
        #expect(store.trust(for: key) == .mismatch(known: replaced.publicKey))
        #expect(store.entries().count == 1)

        try store.remove(store.entries()[0])
        #expect(store.entries().isEmpty)
        #expect(store.trust(for: replaced) == .unknown)
    }

    @Test func readsKnownHostsWrittenByOpenSSH() throws {
        defer { folder.remove() }
        let key = hostKey("a.example")
        let file = folder.url.appending(path: "known_hosts")
        try """
        # a comment
        a.example,10.0.0.1 \(key.openSSH) comment
        |1|hashed= \(key.openSSH)
        *.wild \(key.openSSH)
        @revoked b.example \(key.openSSH)
        garbage
        """.write(to: file, atomically: true, encoding: .utf8)
        let store = KnownHosts(file: file, includeBuiltIn: false)
        #expect(store.entries().map(\.pattern) == ["a.example"])
        #expect(store.trust(for: key) == .trusted)
        // Lines it does not understand are kept when it writes.
        try store.trust(hostKey("c.example"))
        #expect(try folder.read("known_hosts").contains("|1|hashed="))
    }

    @Test func trustsTheHostingServicesFromTheStart() throws {
        defer { folder.remove() }
        let store = KnownHosts(file: folder.url.appending(path: "known_hosts"))
        let github = try SSHPublicKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
        #expect(store.trust(for: SSHHostKey(host: "github.com", port: 22, publicKey: github)) == .trusted)
        let impostor = SSHPrivateKey.generateEd25519(comment: "").publicKey
        #expect(store.trust(for: SSHHostKey(host: "github.com", port: 22, publicKey: impostor))
                == .mismatch(known: github))
        #expect(store.entries().filter(\.isBuiltIn).count == 6)
    }
}
