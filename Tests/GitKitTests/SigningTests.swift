import Foundation
@testable import GitKit
import Testing

/// Commit signing with SSH keys, checked both ways against git and
/// ssh-keygen: what Twig signs, they accept, and what they sign, Twig
/// verifies. Keys are made by ssh-keygen in a temporary folder.
@Suite struct SigningTests {
    let fixture: Fixture
    let folder: TemporaryFolder

    init() throws {
        fixture = try Fixture()
        folder = try TemporaryFolder()
    }

    private func cleanUp() {
        fixture.remove()
        folder.remove()
    }

    /// git, with nothing from the user's setup, signing and verifying with
    /// the test's own allowed-signers file.
    @discardableResult
    private func git(_ arguments: [String], allowFailure: Bool = false) throws -> String {
        try runTool("/usr/bin/git", [
            "-c", "gpg.format=ssh",
            "-c", "gpg.ssh.allowedSignersFile=\(folder.url.appending(path: "allowed_signers").path)"
        ] + arguments, in: fixture.url, home: folder.url, allowFailure: allowFailure)
    }

    private func makeKey(_ options: [String] = ["-t", "ed25519"], name: String = "key") throws -> SSHPrivateKey {
        try SSHPrivateKey(openSSHPrivateKey: try folder.keygen(name, options, comment: "signer@example.com"))
    }

    private func trust(_ key: SSHPrivateKey, as principal: String = "signer@example.com") throws {
        let line = "\(principal) \(key.publicKey.openSSH)\n"
        let file = folder.url.appending(path: "allowed_signers")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try (existing + line).write(to: file, atomically: true, encoding: .utf8)
    }

    @Test(arguments: 0..<4)
    func ssh_keygenAcceptsTwigsSignatures(_ index: Int) throws {
        defer { cleanUp() }
        let key = try makeKey(SSHKeyTests.kinds[index].options)
        try trust(key)
        let message = Data("Some bytes to sign\nover two lines\n".utf8)
        let signature = try SSHSignature.sign(message, with: key)
        try message.write(to: folder.url.appending(path: "message"))
        try (signature + "\n").write(to: folder.url.appending(path: "message.sig"), atomically: true, encoding: .utf8)
        let output = try runTool("/bin/sh", [
            "-c", "/usr/bin/ssh-keygen -Y verify -f allowed_signers -I signer@example.com -n git -s message.sig < message"
        ], in: folder.url)
        #expect(output.contains("Good \"git\" signature for signer@example.com"))

        // And Twig reads back what it wrote.
        #expect(try SSHSignature.verify(signature, message: message).isValid)
    }

    @Test(arguments: 0..<4)
    func twigVerifiesSsh_keygensSignatures(_ index: Int) throws {
        defer { cleanUp() }
        let key = try makeKey(SSHKeyTests.kinds[index].options)
        let message = Data("Signed by ssh-keygen\n".utf8)
        try message.write(to: folder.url.appending(path: "message"))
        try runTool("/usr/bin/ssh-keygen", ["-q", "-Y", "sign", "-n", "git", "-f", "key", "message"], in: folder.url)
        let signature = try folder.read("message.sig")
        let verification = try SSHSignature.verify(signature, message: message)
        #expect(verification.isValid)
        #expect(verification.publicKey == key.publicKey)
        #expect(try SSHSignature.verify(signature, message: Data("Something else\n".utf8)).isValid == false)
        #expect(throws: SSHSignatureError.wrongNamespace) {
            try SSHSignature.verify(signature, message: message, namespace: "file")
        }
    }

    @Test(arguments: [["-t", "ed25519"], ["-t", "ecdsa", "-b", "256"]])
    func gitVerifiesCommitsTwigSigns(_ options: [String]) async throws {
        defer { cleanUp() }
        let key = try makeKey(options)
        try trust(key)
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.write("two\n", to: "a.txt")
        try fixture.git("add", "a.txt")

        let repository = try fixture.open()
        repository.setCommitSigner(CommitSigner(key: key))
        let id = try await repository.commit(message: "Signed")
        #expect(try fixture.git("rev-parse", "HEAD") == id.hex)
        #expect(try fixture.git("log", "-1", "--format=%s") == "Signed")
        #expect(try fixture.git("reflog", "-1", "--format=%gs") == "commit: Signed")
        let output = try git(["verify-commit", "-v", "HEAD"])
        #expect(output.contains("Good \"git\" signature for signer@example.com"))
        #expect(try git(["log", "-1", "--format=%G?"]) == "G")

        let status = try await repository.signatureStatus(
            of: id, trusting: [AllowedSigner(principal: "me", publicKey: key.publicKey.openSSH)]
        )
        #expect(status == .verified(principal: "me", key: key.publicKey))
        #expect(try await repository.signatureStatus(of: id, trusting: []) == .unknownKey(key.publicKey))
    }

    @Test func signsTheFirstCommitAmendsMergesAndRewords() async throws {
        defer { cleanUp() }
        let key = try makeKey()
        try trust(key)
        let repository = try fixture.open()
        repository.setCommitSigner(CommitSigner(key: key))

        try fixture.write("one\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try await repository.commit(message: "Initial")
        #expect(try fixture.git("reflog", "-1", "--format=%gs") == "commit (initial): Initial")
        try git(["verify-commit", "HEAD"])

        try fixture.write("two\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try await repository.amend(message: "Amended", as: GitIdentity(name: "Other", email: "other@example.com"))
        try git(["verify-commit", "HEAD"])
        #expect(try fixture.git("log", "--format=%s|%an|%cn").split(separator: "\n") == ["Amended|Test Author|Other"])
        #expect(try fixture.git("show", "HEAD:a.txt") == "two")
        #expect(try fixture.git("reflog", "-1", "--format=%gs") == "commit (amend): Amended")

        try await repository.rewordHead(message: "Reworded")
        try git(["verify-commit", "HEAD"])
        #expect(try fixture.git("log", "--format=%s").split(separator: "\n") == ["Reworded"])

        // A merge commit, made by the merge code through the same choke point.
        try fixture.git("switch", "--quiet", "-c", "topic")
        try fixture.commit("b.txt", "b\n", message: "Topic")
        try fixture.git("switch", "--quiet", "main")
        try fixture.commit("c.txt", "c\n", message: "Main")
        // Opened again: libgit2 can miss an index git rewrote within the same second.
        let merging = try fixture.open()
        merging.setCommitSigner(CommitSigner(key: key))
        _ = try await merging.merge("refs/heads/topic", mode: .alwaysCommit)
        #expect(try fixture.git("rev-list", "--parents", "-1", "HEAD").split(separator: " ").count == 3)
        try git(["verify-commit", "HEAD"])

        // A rebase signs each commit it makes.
        try fixture.git("switch", "--quiet", "-c", "feature", "HEAD~1")
        try fixture.commit("d.txt", "d\n", message: "Feature one")
        try fixture.commit("e.txt", "e\n", message: "Feature two")
        let rebasing = try fixture.open()
        rebasing.setCommitSigner(CommitSigner(key: key))
        _ = try await rebasing.rebase(onto: "refs/heads/main")
        #expect(try fixture.git("log", "-2", "--format=%s").split(separator: "\n") == ["Feature two", "Feature one"])
        try git(["verify-commit", "HEAD"])
        try git(["verify-commit", "HEAD~1"])
    }

    @Test func committingAsAnotherIdentity() async throws {
        defer { cleanUp() }
        try fixture.commit("a.txt", "one\n", message: "First")
        try fixture.write("two\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        let repository = try fixture.open()
        try await repository.commit(message: "By someone else", as: GitIdentity(name: "Someone", email: "someone@example.com"))
        #expect(try fixture.git("log", "-1", "--format=%an <%ae>|%cn <%ce>") == "Someone <someone@example.com>|Someone <someone@example.com>")
        // Not signed without a signer.
        let id = try #require(OID(hex: fixture.git("rev-parse", "HEAD")))
        #expect(try await repository.signatureStatus(of: id, trusting: []) == .unsigned)
    }

    @Test func verifiesCommitsGitSigns() async throws {
        defer { cleanUp() }
        let key = try makeKey()
        try trust(key)
        try fixture.write("one\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try git(["-c", "user.signingkey=\(folder.url.appending(path: "key").path)", "commit", "--quiet", "-S", "-m", "Signed by git"])
        let id = try #require(OID(hex: fixture.git("rev-parse", "HEAD")))

        let repository = try fixture.open()
        let trusted = AllowedSigner.parse(try String(contentsOf: folder.url.appending(path: "allowed_signers"), encoding: .utf8))
        #expect(try await repository.signatureStatus(of: id, trusting: trusted)
                == .verified(principal: "signer@example.com", key: key.publicKey))
        #expect(try await repository.signatureStatus(of: id, trusting: []) == .unknownKey(key.publicKey))

        // The same signature on other contents does not hold.
        let raw = try fixture.git("cat-file", "commit", "HEAD")
        let tampered = raw.replacingOccurrences(of: "Signed by git", with: "Signed by someone")
        try (tampered + "\n").write(to: folder.url.appending(path: "tampered"), atomically: true, encoding: .utf8)
        let forged = try fixture.git("hash-object", "-t", "commit", "-w", folder.url.appending(path: "tampered").path)
        guard case .invalid = try await repository.signatureStatus(of: try #require(OID(hex: forged)), trusting: trusted) else {
            Issue.record("A changed commit should not verify")
            return
        }
    }

    @Test func namesSignaturesItCannotCheck() async throws {
        defer { cleanUp() }
        try fixture.commit("a.txt", "one\n", message: "First")
        let raw = try fixture.git("cat-file", "commit", "HEAD")
        let parts = raw.components(separatedBy: "\n\n")
        let pgp = parts[0] + "\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n iQEzBAABCAAdFiEE\n -----END PGP SIGNATURE-----\n\n" + parts.dropFirst().joined(separator: "\n\n") + "\n"
        try pgp.write(to: folder.url.appending(path: "pgp"), atomically: true, encoding: .utf8)
        let id = try fixture.git("hash-object", "-t", "commit", "-w", folder.url.appending(path: "pgp").path)
        let repository = try fixture.open()
        #expect(try await repository.signatureStatus(of: try #require(OID(hex: id)), trusting: []) == .unverifiable(format: "GPG"))
    }

    @Test func readsAllowedSignersFiles() throws {
        defer { cleanUp() }
        let key = try makeKey()
        let other = try makeKey(["-t", "ecdsa", "-b", "256"], name: "other")
        let text = """
        # Trusted people
        signer@example.com \(key.publicKey.openSSH) a comment

        a@example.com,b@example.com namespaces="git,file" \(other.publicKey.openSSH)
        files@example.com namespaces="file" \(key.publicKey.openSSH)
        broken@example.com ssh-ed25519 not-base64
        """
        let signers = AllowedSigner.parse(text)
        #expect(signers == [
            AllowedSigner(principal: "signer@example.com", publicKey: key.publicKey.openSSH),
            AllowedSigner(principal: "a@example.com,b@example.com", publicKey: other.publicKey.openSSH)
        ])
    }
}
