import GitKit
import SwiftUI
import UniformTypeIdentifiers

/// The identities commits are made as, how commits are signed, and whose
/// signatures are trusted.
struct IdentitySettingsSection: View {
    @Bindable private var profiles = AuthorProfiles.shared
    @State private var keys: [StoredSSHKey] = []
    @State private var editing: AuthorProfile?
    @State private var removing: AuthorProfile?
    @State private var isAddingSigner = false
    @State private var isImportingSigners = false
    @State private var error: PresentedError?

    var body: some View {
        Section {
            ForEach(profiles.profiles) { profile in
                LabeledContent {
                    HStack {
                        if profile.id == profiles.defaultProfile?.id {
                            Text("Default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Make Default", systemImage: "star") { attempt { try profiles.makeDefault(profile) } }
                                .help("Commit as this identity unless a repository or a commit says otherwise")
                        }
                        Button("Edit", systemImage: "pencil") { editing = profile }
                            .help("Edit this identity")
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { removing = profile }
                            .help("Remove this identity")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                } label: {
                    Text(profile.name)
                    Text(detail(for: profile))
                }
            }
            if profiles.profiles.isEmpty {
                Text("No identities yet")
                    .foregroundStyle(.secondary)
            }
            Button("Add Identity…", systemImage: "plus") {
                editing = AuthorProfile(name: "", email: "")
            }
        } header: {
            Text("Identities")
        } footer: {
            Text("The names and emails you commit as. The default is used everywhere unless a repository picks another, or you pick one for a single commit from the composer’s “As” menu.")
        }

        Section {
            Toggle("Sign Commits", isOn: $profiles.signsCommits)
            Picker("Signing Key", selection: $profiles.signingKeyID) {
                Text(keys.first.map { "First Key (\(name(of: $0)))" } ?? "No Keys").tag(String?.none)
                ForEach(keys) { key in
                    Text(name(of: key)).tag(String?.some(key.id))
                }
            }
            .disabled(keys.isEmpty)
        } header: {
            Text("Commit Signing")
        } footer: {
            Text("Commits are signed with an SSH key from below, as git does with gpg.format=ssh. Add the key’s public half to your hosting service as a signing key for it to show as verified there. An identity or a repository can turn signing on or off for itself.")
        }

        Section {
            ForEach(profiles.allowedSigners) { signer in
                LabeledContent {
                    Button("Remove", systemImage: "minus.circle", role: .destructive) {
                        profiles.allowedSigners.removeAll { $0 == signer }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Stop trusting this key")
                } label: {
                    Text(signer.principal)
                    Text(signer.key.map { "\($0.displayName) · \($0.fingerprint)" } ?? signer.publicKey)
                        .font(.smallCode)
                        .textSelection(.enabled)
                }
            }
            if profiles.allowedSigners.isEmpty {
                Text("No other signers")
                    .foregroundStyle(.secondary)
            }
            Button("Add Signer…", systemImage: "plus") { isAddingSigner = true }
            Button("Import allowed_signers File…", systemImage: "square.and.arrow.down") { isImportingSigners = true }
        } header: {
            Text("Allowed Signers")
        } footer: {
            Text("Other people’s SSH keys, trusted to sign as them. A commit signed by one of these, or by one of your own keys, shows as verified.")
        }
        .onAppear(perform: load)
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile, keys: keys) { saved in
                attempt { try profiles.save(saved) }
            }
        }
        .sheet(isPresented: $isAddingSigner) {
            SignerEditor { signer in
                profiles.allowedSigners.append(signer)
            }
        }
        .fileImporter(isPresented: $isImportingSigners, allowedContentTypes: [.plainText, .data]) { result in
            importSigners(result)
        }
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
            titleVisibility: .visible,
            presenting: removing
        ) { profile in
            Button("Remove Identity", role: .destructive) { attempt { try profiles.remove(profile) } }
        } message: { _ in
            Text("Repositories that commit as it go back to the default identity. Commits already made keep their author.")
        }
        .alert(for: $error)
    }

    private func load() {
        // The author written to the global configuration some other way.
        profiles.adoptGlobalIdentity(GitEnvironment.globalIdentity())
        do {
            keys = try SSHKeyStore.shared.keys()
        } catch {
            self.error = PresentedError(error)
        }
    }

    private func detail(for profile: AuthorProfile) -> String {
        var parts = [profile.email]
        if let id = profile.signingKeyID, let key = keys.first(where: { $0.id == id }) {
            parts.append("signs with \(name(of: key))")
        }
        switch profile.signsCommits {
        case true?: parts.append("always signs")
        case false?: parts.append("never signs")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    private func name(of key: StoredSSHKey) -> String {
        key.comment.isEmpty ? "\(key.kind.displayName) \(key.fingerprint.suffix(8))" : key.comment
    }

    private func importSigners(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            let found = AllowedSigner.parse(try String(contentsOf: url, encoding: .utf8))
            guard !found.isEmpty else { throw AllowedSignersError.nothingFound }
            for signer in found where !profiles.allowedSigners.contains(signer) {
                profiles.allowedSigners.append(signer)
            }
        } catch {
            self.error = PresentedError(error)
        }
    }

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            self.error = PresentedError(error)
        }
    }
}

private enum AllowedSignersError: LocalizedError {
    case nothingFound

    var errorDescription: String? {
        "The file holds no signers Twig can use. Each line should be “email key-type key”, as in git’s allowed signers file."
    }
}

/// Edits one identity: its name and email, and how it signs.
private struct ProfileEditor: View {
    @State var profile: AuthorProfile
    var keys: [StoredSSHKey]
    var save: (AuthorProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $profile.name)
                        .textContentType(.name)
                    TextField("Email", text: $profile.email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                }
                Section {
                    Picker("Sign Commits", selection: $profile.signsCommits) {
                        Text("As Set for All").tag(Bool?.none)
                        Text("Always").tag(Bool?.some(true))
                        Text("Never").tag(Bool?.some(false))
                    }
                    Picker("Signing Key", selection: $profile.signingKeyID) {
                        Text("The Usual Key").tag(String?.none)
                        ForEach(keys) { key in
                            Text(key.comment.isEmpty ? key.kind.displayName : key.comment).tag(String?.some(key.id))
                        }
                    }
                } footer: {
                    Text("A work identity can sign with its own key, which you add to that account’s hosting service.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(profile.name.isEmpty ? "New Identity" : profile.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
                        profile.email = profile.email.trimmingCharacters(in: .whitespaces)
                        save(profile)
                        dismiss()
                    }
                    .disabled(!profile.isComplete)
                }
            }
        }
        .sheetMinimumSize(width: 420, height: 340)
    }
}

/// Adds someone else's public key as trusted to sign as them.
private struct SignerEditor: View {
    var add: (AllowedSigner) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var principal = ""
    @State private var publicKey = ""

    var body: some View {
        let signer = AllowedSigner(
            principal: principal.trimmingCharacters(in: .whitespaces),
            publicKey: publicKey.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
        )
        NavigationStack {
            Form {
                TextField("Email", text: $principal, prompt: Text("someone@example.com"))
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                Section {
                    TextField("Public Key", text: $publicKey, prompt: Text("ssh-ed25519 AAAA…"), axis: .vertical)
                        .font(.code)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                } footer: {
                    if !publicKey.isEmpty, signer.key == nil {
                        Text("This is not an Ed25519 or ECDSA public key.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Signer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        add(signer)
                        dismiss()
                    }
                    .disabled(signer.principal.isEmpty || signer.key?.kind == nil)
                }
            }
        }
        .sheetMinimumSize(width: 420, height: 300)
    }
}
