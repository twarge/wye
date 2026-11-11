import SwiftUI

/// The repositories of the signed-in accounts, to pick one to clone.
struct CloneFromAccountSheet: View {
    /// Called with the chosen repository's address.
    var choose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(HostingPreferences.prefersSSHKey) private var prefersSSH = false
    @State private var accountID: UUID?
    @State private var filter = RepositoryListFilter.member
    @State private var query = ""
    @State private var items: [HostingRepository] = []
    @State private var next: PageCursor?
    @State private var isLoading = false
    @State private var failure: String?
    @State private var selection: HostingRepository.ID?
    @State private var isAdding = false
    private var changes = AccountChangeCounter.shared

    init(choose: @escaping (String) -> Void) {
        self.choose = choose
    }

    private var accounts: [HostingAccount] {
        _ = changes.count
        return ((try? AccountStore.shared.accounts()) ?? []).filter(\.usesService)
    }

    private var account: HostingAccount? {
        accounts.first { $0.id == accountID } ?? accounts.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
                    } description: {
                        Text("Sign in to GitHub, GitLab, Bitbucket, Gitea or Forgejo to list your repositories.")
                    } actions: {
                        Button("Add Account…") { isAdding = true }
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Clone from Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") { chooseSelected() }
                        .disabled(selected == nil)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .sheet(isPresented: $isAdding) {
            SignInSheet { accountID = $0.id }
        }
    }

    private var selected: HostingRepository? {
        items.first { $0.id == selection }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Account", selection: Binding { account?.id } set: { accountID = $0 }) {
                    ForEach(accounts) { account in
                        Text(account.title).tag(UUID?.some(account.id))
                    }
                }
                Picker("Show", selection: $filter) {
                    ForEach(RepositoryListFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Clone With", selection: $prefersSSH) {
                    Text("HTTPS").tag(false)
                    Text("SSH").tag(true)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(items) { repository in
                    HostedRepositoryRow(repository: repository)
                        .tag(repository.id)
                }
                if next != nil {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .task(id: items.count) { await load(more: true) }
                }
            }
            .contextMenu(forSelectionType: HostingRepository.ID.self, menu: { _ in }, primaryAction: { _ in chooseSelected() })
            .overlay {
                if items.isEmpty {
                    if isLoading {
                        ProgressView()
                    } else if let failure {
                        ContentUnavailableView("Couldn’t Load", systemImage: "exclamationmark.triangle", description: Text(failure))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, prompt: "Name")
        }
        .task(id: "\(account?.id.uuidString ?? "")|\(filter.rawValue)|\(query)") {
            // Typing settles before a search goes out.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load(more: false)
        }
    }

    private func load(more: Bool) async {
        guard let account, !(more && (next == nil || isLoading)) else { return }
        isLoading = true
        defer { isLoading = false }
        if !more {
            items = []
            next = nil
            failure = nil
        }
        do {
            let page = try await account.service().repositories(filter, query: query, page: more ? next : nil)
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            next = page.next
        } catch is CancellationError {
        } catch {
            next = nil
            failure = error.localizedDescription
        }
    }

    private func chooseSelected() {
        guard let repository = selected, let account else { return }
        let url = repository.cloneURL(preferSSH: prefersSSH)
        // A repository cloned with an account that is not its host's
        // default keeps using that account.
        if AccountStore.shared.defaultAccount(forHost: account.host)?.id != account.id {
            AccountStore.shared.setAccount(account.id, forRemoteURL: url)
        }
        choose(url)
        dismiss()
    }
}

private struct HostedRepositoryRow: View {
    var repository: HostingRepository

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(repository.path.fullPath)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if repository.isPrivate {
                    Image(systemName: "lock.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Private")
                }
                Spacer(minLength: 4)
                if let branch = repository.defaultBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            if let description = repository.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .help(repository.isPrivate ? "Private" : "Public")
    }
}
