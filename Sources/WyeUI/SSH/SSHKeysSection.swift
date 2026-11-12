import GitKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings' list of SSH keys, with ways to make, import and remove them,
/// and the trusted host keys.
struct SSHKeysSection: View {
    @State private var keys: [StoredSSHKey] = []
    @State private var deleting: StoredSSHKey?
    @State private var isCreating = false
    @State private var isImporting = false
    @State private var isShowingHosts = false
    @State private var error: Notice?

    /// Moves the keys into iCloud Keychain or out of it. The setting only
    /// changes once they have moved.
    private func setSynced(_ synced: Bool) {
        do {
            try SSHKeyStore.shared.setSynced(synced)
            syncsKeys = synced
        } catch {
            self.error = Notice(error)
        }
        reload()
    }
    @State private var focus = SettingsFocus.shared
    @AppStorage(SSHKeyPreferences.syncsKey) private var syncsKeys = false

    var body: some View {
        Section {
            if let notice = focus.sshKeyNotice {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notice.explanation(hasKeys: !keys.isEmpty))
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = SSHKeyHelp.settingsURL(for: notice.host) {
                            Link("Open \(notice.host)’s SSH Key Settings", destination: url)
                        }
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .id(SettingsFocus.sshKeysAnchor)
            }
            ForEach(keys) { key in
                LabeledContent {
                    HStack {
                        Button("Copy Public Key", systemImage: "doc.on.doc") {
                            Platform.copyToClipboard(key.publicKeyLine)
                        }
                        .help("Copy the public key, to add to a hosting service")
                        Button("Delete", systemImage: "minus.circle", role: .destructive) { deleting = key }
                            .help("Delete this key")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                } label: {
                    Text(key.comment.isEmpty ? key.kind.displayName : key.comment)
                    Text("\(key.kind.displayName) · \(key.fingerprint)")
                        .font(.smallCode)
                        .textSelection(.enabled)
                    if key.isSynced {
                        Label("In iCloud Keychain", systemImage: "icloud")
                            .font(.caption)
                    }
                }
                .contextMenu {
                    Button("Copy Public Key", systemImage: "doc.on.doc") {
                        Platform.copyToClipboard(key.publicKeyLine)
                    }
                    Button("Delete…", systemImage: "trash", role: .destructive) { deleting = key }
                }
            }
            if keys.isEmpty {
                Text("No SSH keys")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Create Key…") { isCreating = true }
                Button("Import Key…") { isImporting = true }
                Spacer()
                Button("Known Hosts…") { isShowingHosts = true }
            }
            Toggle("Sync Keys with iCloud Keychain", isOn: Binding { syncsKeys } set: { setSynced($0) })
            NoticeRow(notice: $error)
        } header: {
            Text("SSH Keys")
        } footer: {
            Text(syncsKeys
                ? "Kept in iCloud Keychain, end-to-end encrypted, on every device signed in to your Apple Account. Wye offers each key in turn to SSH remotes; add a key’s public half to your account on the host. Ed25519 and ECDSA keys work; RSA keys don’t."
                : "Kept in the Keychain on this device. Wye offers each key in turn to SSH remotes; add a key’s public half to your account on the host. Ed25519 and ECDSA keys work; RSA keys don’t.")
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Delete the key “\(deleting.map(name) ?? "")”?",
            isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
            titleVisibility: .visible,
            presenting: deleting
        ) { key in
            Button("Delete Key", role: .destructive) { delete(key) }
        } message: { key in
            Text("Its fingerprint is \(key.fingerprint). Hosts that know only this key will refuse Wye. A deleted key can’t be recovered, unless you have a copy elsewhere.")
        }
        .sheet(isPresented: $isCreating, onDismiss: reload) {
            NewSSHKeySheet()
        }
        .sheet(isPresented: $isImporting, onDismiss: reload) {
            ImportSSHKeySheet()
        }
        .sheet(isPresented: $isShowingHosts) {
            KnownHostsSheet()
        }
    }

    private func name(_ key: StoredSSHKey) -> String {
        key.comment.isEmpty ? key.kind.displayName : key.comment
    }

    private func reload() {
        do {
            keys = try SSHKeyStore.shared.keys()
        } catch {
            self.error = Notice(error)
        }
    }

    private func delete(_ key: StoredSSHKey) {
        do {
            try SSHKeyStore.shared.remove(key)
        } catch {
            self.error = Notice(error)
        }
        reload()
    }
}

/// Makes a new Ed25519 key.
private struct NewSSHKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var created: StoredSSHKey?
    @State private var error: Notice?

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    Section {
                        SSHPublicKeyRow(key: created)
                    } header: {
                        Text("Public Key")
                    } footer: {
                        Text("Add this to your account on the hosting service, in its SSH key settings.")
                    }
                } else {
                    Section {
                        TextField("Comment", text: $comment)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("An Ed25519 key. The comment is how the key is named on the hosting service.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New SSH Key")
            .toolbar {
                if created == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { create() }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .frame(minWidth: 440)
        .onAppear { comment = SSHKeyHelp.defaultComment }
        .notice(for: $error)
    }

    private func create() {
        do {
            let key = SSHPrivateKey.generateEd25519(comment: comment.trimmingCharacters(in: .whitespacesAndNewlines))
            created = try SSHKeyStore.shared.add(key)
        } catch {
            self.error = Notice(error)
        }
    }
}

/// Imports a private key in OpenSSH's format, from a file or pasted.
private struct ImportSSHKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var passphrase = ""
    @State private var comment = ""
    @State private var isEncrypted = false
    @State private var isChoosingFile = false
    @State private var isWorking = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.smallCode)
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                    Button("Choose File…") { isChoosingFile = true }
                } header: {
                    Text("Private Key")
                } footer: {
                    Text("Paste a key that begins “-----BEGIN OPENSSH PRIVATE KEY-----”, or choose its file, such as id_ed25519. Wye keeps a copy in the Keychain.")
                }
                if isEncrypted {
                    Section("Passphrase") {
                        SecureField("Passphrase", text: $passphrase)
                            .textContentType(.password)
                    }
                }
                Section {
                    TextField("Comment", text: $comment, prompt: Text("From the key"))
                        .autocorrectionDisabled()
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import SSH Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importKey() }
                        .disabled(text.isEmpty || isWorking || (isEncrypted && passphrase.isEmpty))
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .onChange(of: text) {
            problem = nil
            isEncrypted = (try? SSHPrivateKey.isEncrypted(openSSHPrivateKey: text)) ?? false
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                let isScoped = url.startAccessingSecurityScopedResource()
                defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    text = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    problem = "That file can’t be read as a key: \(error.localizedDescription)"
                }
            case .failure(let failure):
                problem = failure.localizedDescription
            }
        }
        // Keys are usually in ~/.ssh, a hidden folder: start at the home
        // folder with hidden files showing so it can be found.
        .fileDialogDefaultDirectory(Platform.userHomeDirectory)
        .fileDialogBrowserOptions(.includeHiddenFiles)
    }

    private func importKey() {
        let text = text, passphrase = isEncrypted ? passphrase : nil
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        problem = nil
        Task {
            // Deriving the key from a passphrase takes a moment, on purpose.
            let result = await Task.detached {
                Result { try SSHPrivateKey(openSSHPrivateKey: text, passphrase: passphrase) }
            }.value
            isWorking = false
            do {
                var key = try result.get()
                if !comment.isEmpty { key.comment = comment }
                try SSHKeyStore.shared.add(key)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The host keys Wye trusts, to stop trusting one.
private struct KnownHostsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [KnownHosts.Entry] = []
    @State private var error: Notice?

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.pattern)
                            if entry.isBuiltIn {
                                Text("Built In")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("\(entry.publicKey.displayName) · \(entry.publicKey.fingerprint)")
                            .font(.smallCode)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        if !entry.isBuiltIn {
                            Button("Stop Trusting", systemImage: "trash", role: .destructive) { remove(entry) }
                        }
                    }
                    .swipeActions {
                        if !entry.isBuiltIn {
                            Button("Stop Trusting", systemImage: "trash", role: .destructive) { remove(entry) }
                        }
                    }
                }
            }
            .navigationTitle("Known Hosts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear(perform: reload)
        .notice(for: $error)
    }

    private func reload() {
        entries = SSHKeyStore.shared.knownHosts.entries()
    }

    private func remove(_ entry: KnownHosts.Entry) {
        do {
            try SSHKeyStore.shared.knownHosts.remove(entry)
        } catch {
            self.error = Notice(error)
        }
        reload()
    }
}
