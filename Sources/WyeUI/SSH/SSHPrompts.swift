import Foundation
import GitKit
import SwiftUI

/// An SSH server's key that is not trusted yet, or that changed.
struct HostKeyPrompt: Identifiable {
    let id = UUID()
    let hostKey: SSHHostKey
    /// The key trusted for the host before, when the one it presents is a
    /// different one.
    let previous: SSHPublicKey?

    init?(_ error: RemoteError) {
        switch error {
        case .unknownHostKey(let key):
            hostKey = key
            previous = nil
        case .hostKeyChanged(let key, let known):
            hostKey = key
            previous = known
        default:
            return nil
        }
    }

    var hasChanged: Bool { previous != nil }
}

/// An SSH server that wants a key: Wye has none, or none it accepts.
struct SSHKeyPrompt: Identifiable {
    let id = UUID()
    let host: String
    let username: String
    let wasRejected: Bool

    init?(_ error: RemoteError) {
        switch error {
        case .sshKeyRequired(let host, let username):
            self.host = host
            self.username = username
            wasRejected = false
        case .sshKeysRejected(let host, let username):
            self.host = host
            self.username = username
            wasRejected = true
        default:
            return nil
        }
    }

    /// Why a key is needed and what to do about it.
    func explanation(hasKeys: Bool) -> String {
        guard hasKeys else {
            return "\(host) logs in with an SSH key, and Wye has none yet. Create or import one, add its public key to your account on \(host), then try again."
        }
        let start = wasRejected
            ? "\(host) did not accept Wye’s keys for “\(username)”."
            : "\(host) wants an SSH key."
        return start + " Add a public key below to your account on \(host), then try again."
    }
}

extension View {
    /// The sheets a ``CredentialBroker`` asks with: a token, a host's key.
    func credentialPrompts(_ broker: CredentialBroker) -> some View {
        modifier(CredentialPrompts(broker: broker))
    }
}

private struct CredentialPrompts: ViewModifier {
    @Bindable var broker: CredentialBroker

    func body(content: Content) -> some View {
        content
            .sheet(item: $broker.prompt) { prompt in
                CredentialsSheet(prompt: prompt, broker: broker)
                    .onDisappear { broker.dismissed(prompt.id) }
            }
            .sheet(item: $broker.hostKeyPrompt) { prompt in
                HostKeySheet(prompt: prompt, broker: broker)
                    .onDisappear { broker.dismissed(prompt.id) }
            }
    }
}

/// Asks whether to trust an SSH server's key, as ssh does on first contact,
/// and warns plainly when a known server's key has changed.
struct HostKeySheet: View {
    let prompt: HostKeyPrompt
    var broker: CredentialBroker

    @State private var hasChecked = false
    @State private var error: Notice?

    private var host: String { prompt.hostKey.host }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if prompt.hasChanged {
                        Label {
                            Text("The key \(host) presents is not the one Wye trusted for it.")
                                .bold()
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        Text("Someone may be intercepting the connection to read or change what you send, or the host’s key may have been replaced. Don’t continue unless the host’s owners have announced a new key and its fingerprint matches.")
                    } else {
                        Label("The authenticity of host “\(host)” can’t be established.", systemImage: "lock.shield")
                        Text("Connect only if this is the fingerprint the host publishes. The hosting services list theirs in their documentation.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section(prompt.hasChanged ? "Presented Now" : "Fingerprint") {
                    fingerprint(prompt.hostKey.publicKey)
                }
                if let previous = prompt.previous {
                    Section("Trusted Before") {
                        fingerprint(previous)
                    }
                    Section {
                        Toggle("I have checked the new fingerprint with the host’s owners", isOn: $hasChecked)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(prompt.hasChanged ? "Host Key Changed" : "Unknown Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { broker.decline() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if prompt.hasChanged {
                        Button("Trust New Key", role: .destructive) { broker.proceed() }
                            .disabled(!hasChecked)
                    } else {
                        Button("Trust and Connect") { broker.proceed() }
                    }
                }
            }
        }
        .frame(minWidth: 440)
        .notice(for: $error)
    }

    private func fingerprint(_ key: SSHPublicKey) -> some View {
        LabeledContent(key.displayName) {
            Text(key.fingerprint)
                .font(.code)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// One key's public half, to copy into a hosting service.
struct SSHPublicKeyRow: View {
    let key: StoredSSHKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.comment.isEmpty ? key.kind.displayName : key.comment)
                Spacer()
                Button("Copy Public Key", systemImage: "doc.on.doc") {
                    Platform.copyToClipboard(key.publicKeyLine)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy the public key, to add to a hosting service")
            }
            Text(key.publicKeyLine)
                .font(.smallCode)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

enum SSHKeyHelp {
    @MainActor static var defaultComment: String {
        "Wye on \(Platform.deviceName)"
    }

    /// Where the hosting services take a new public key.
    static func settingsURL(for host: String) -> URL? {
        switch host.lowercased() {
        case "github.com": URL(string: "https://github.com/settings/ssh/new")
        case "gitlab.com": URL(string: "https://gitlab.com/-/user_settings/ssh_keys")
        case "bitbucket.org": URL(string: "https://bitbucket.org/account/settings/ssh-keys/")
        default: nil
        }
    }
}
