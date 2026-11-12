import SwiftUI

/// The accounts Wye signs in to hosting services and git hosts with:
/// several per host if need be, one of them each host's default.
struct AccountsSection: View {
    @State private var accounts: [HostingAccount] = []
    @State private var defaults: [String: UUID] = [:]
    @State private var isAdding = false
    @State private var signingInAgain: HostingAccount?
    @State private var removing: HostingAccount?
    @State private var error: Notice?
    private var changes = AccountChangeCounter.shared

    var body: some View {
        Section {
            ForEach(accounts) { account in
                AccountRow(
                    account: account,
                    isDefault: defaults[account.host] == account.id,
                    hasOthers: accounts.contains { $0.host == account.host && $0.id != account.id },
                    makeDefault: { AccountStore.shared.setDefault(account.id, forHost: account.host) },
                    signInAgain: { signingInAgain = account },
                    remove: { removing = account }
                )
            }
            if accounts.isEmpty {
                Text("No accounts")
                    .foregroundStyle(.secondary)
            }
            Button("Add Account…", systemImage: "plus") { isAdding = true }
            NoticeRow(notice: $error)
        } header: {
            Text("Accounts")
        } footer: {
            Text("Accounts on GitHub, GitLab, Bitbucket, Gitea and Forgejo, for cloning, publishing and pull requests, "
                 + "and tokens git asked for. Tokens are kept in the Keychain. Each host uses its default account "
                 + "unless a remote’s menu chooses another.")
        }
        .onAppear(perform: reload)
        .onChange(of: changes.count) { reload() }
        .sheet(isPresented: $isAdding) {
            SignInSheet()
        }
        .sheet(item: $signingInAgain) { account in
            SignInSheet(initialKind: account.kind ?? .github, initialHost: account.host)
        }
        .confirmationDialog(
            "Remove \(removing?.title ?? "")?",
            isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
            titleVisibility: .visible,
            presenting: removing
        ) { account in
            Button("Remove Account", role: .destructive) { remove(account) }
        } message: { account in
            Text("Wye forgets the token for \(account.login). Remotes on \(account.host) use another account, "
                 + "or ask for a token. The token itself stays valid on the service until you revoke it there.")
        }
    }

    private func reload() {
        do {
            accounts = try AccountStore.shared.accounts()
            var defaults: [String: UUID] = [:]
            for host in Set(accounts.map(\.host)) {
                defaults[host] = AccountStore.shared.defaultAccount(forHost: host)?.id
            }
            self.defaults = defaults
        } catch {
            self.error = Notice(error)
        }
    }

    private func remove(_ account: HostingAccount) {
        do {
            try AccountStore.shared.remove(account.id)
            CredentialStore.shared.forgetUnsaved(host: account.host)
        } catch {
            self.error = Notice(error)
        }
        reload()
    }
}

private struct AccountRow: View {
    var account: HostingAccount
    var isDefault: Bool
    var hasOthers: Bool
    var makeDefault: () -> Void
    var signInAgain: () -> Void
    var remove: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if isDefault && hasOthers {
                    Text("Default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Menu("Actions", systemImage: "ellipsis.circle") {
                    if hasOthers {
                        Button("Use by Default for \(account.host)", systemImage: "star") { makeDefault() }
                            .disabled(isDefault)
                    }
                    if account.kind != nil {
                        Button("Sign In Again…", systemImage: "arrow.clockwise") { signInAgain() }
                    }
                    Button("Remove…", systemImage: "minus.circle", role: .destructive) { remove() }
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        } label: {
            HStack(spacing: 10) {
                AccountAvatar(url: account.avatarURL, name: account.login, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name.map { "\($0) (\(account.login))" } ?? account.login)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitle: String {
        let service = account.kind?.title ?? "Git host"
        let note = account.signIn == .gitPrompt ? " · token for git only" : ""
        return "\(service) · \(account.host)\(note)"
    }
}
