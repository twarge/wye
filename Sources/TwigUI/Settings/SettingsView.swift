import GitKit
import SwiftUI

struct SettingsView: View {
    @State private var name = ""
    @State private var email = ""
    @State private var error: PresentedError?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textContentType(.name)
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
            } header: {
                Text("Author")
            } footer: {
                Text("Recorded as the author of the commits you make in Twig, unless a repository sets its own.")
            }

            AccountsSection()

            Section("About") {
                LabeledContent("libgit2", value: GitEnvironment.libgit2Version)
                AcknowledgementsButton()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let identity = GitEnvironment.globalIdentity()
            name = identity?.name ?? ""
            email = identity?.email ?? ""
        }
        .onChange(of: [name, email]) {
            save()
        }
        .alert(for: $error)
    }

    /// Saves once both fields hold something; half an identity is no use to git.
    private func save() {
        let identity = GitIdentity(
            name: name.trimmingCharacters(in: .whitespaces),
            email: email.trimmingCharacters(in: .whitespaces)
        )
        guard !identity.name.isEmpty, !identity.email.isEmpty, identity != GitEnvironment.globalIdentity() else {
            return
        }
        do {
            try GitEnvironment.setGlobalIdentity(identity)
        } catch {
            self.error = PresentedError(error)
        }
    }
}

/// The hosts Twig keeps an access token for, in the Keychain.
private struct AccountsSection: View {
    @State private var accounts: [SavedAccount] = []
    @State private var removing: SavedAccount?
    @State private var error: PresentedError?

    var body: some View {
        Section {
            ForEach(accounts) { account in
                LabeledContent {
                    Button("Remove", systemImage: "minus.circle", role: .destructive) { removing = account }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove the token for \(account.host)")
                } label: {
                    Text(account.host)
                    Text(account.username)
                }
            }
            if accounts.isEmpty {
                Text("No saved tokens")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Access tokens saved in the Keychain, one per host. Twig asks for one when a remote wants it.")
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Remove the token for \(removing?.host ?? "")?",
            isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
            titleVisibility: .visible,
            presenting: removing
        ) { account in
            Button("Remove Token", role: .destructive) { remove(account) }
        } message: { _ in
            Text("Twig will ask for a token the next time a remote on this host wants one.")
        }
        .alert(for: $error)
    }

    private func reload() {
        do {
            accounts = try CredentialStore.shared.savedAccounts()
        } catch {
            self.error = PresentedError(error)
        }
    }

    private func remove(_ account: SavedAccount) {
        do {
            try CredentialStore.shared.remove(host: account.host)
        } catch {
            self.error = PresentedError(error)
        }
        reload()
    }
}
