import Foundation
import GitKit
import Testing
@testable import WyeUI

/// Which SSH failures turn into which prompt.
@Suite struct SSHPromptTests {
    let hostKey = SSHHostKey(
        host: "example.com", port: 22, publicKey: SSHPrivateKey.generateEd25519(comment: "").publicKey
    )

    @Test func hostKeyFailuresAskToTrust() throws {
        let unknown = try #require(HostKeyPrompt(.unknownHostKey(hostKey)))
        #expect(unknown.hostKey == hostKey)
        #expect(!unknown.hasChanged)

        let previous = SSHPrivateKey.generateEd25519(comment: "").publicKey
        let changed = try #require(HostKeyPrompt(.hostKeyChanged(hostKey, known: previous)))
        #expect(changed.hasChanged)
        #expect(changed.previous == previous)

        #expect(HostKeyPrompt(.sshKeyRequired(host: "example.com", username: "git")) == nil)
    }

    @Test func keyFailuresAskForAKey() throws {
        let missing = try #require(SSHKeyPrompt(.sshKeyRequired(host: "example.com", username: "git")))
        #expect(!missing.wasRejected)
        let rejected = try #require(SSHKeyPrompt(.sshKeysRejected(host: "example.com", username: "me")))
        #expect(rejected.wasRejected)
        #expect(rejected.username == "me")
        #expect(SSHKeyPrompt(.unknownHostKey(hostKey)) == nil)
        #expect(SSHKeyPrompt(.credentialsRequired(host: "example.com", username: nil)) == nil)
    }

    @Test func knowsWhereTheHostingServicesTakeKeys() {
        #expect(SSHKeyHelp.settingsURL(for: "GitHub.com")?.host() == "github.com")
        #expect(SSHKeyHelp.settingsURL(for: "gitlab.com") != nil)
        #expect(SSHKeyHelp.settingsURL(for: "bitbucket.org") != nil)
        #expect(SSHKeyHelp.settingsURL(for: "git.example.com") == nil)
    }
}
