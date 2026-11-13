import SwiftUI

extension View {
    /// The hosting features' sheets: publish, a new pull request, and the
    /// account a remote uses.
    func hostingDialogs(_ model: RepositoryModel) -> some View {
        modifier(HostingDialogs(model: model))
    }
}

private struct HostingDialogs: ViewModifier {
    @Bindable var model: RepositoryModel

    func body(content: Content) -> some View {
        @Bindable var hosting = model.hosting
        content
            .sheet(item: $hosting.sheet) { sheet in
                switch sheet {
                case .publish(let kind):
                    PublishSheet(model: model, kind: kind)
                case .newPullRequest(let head):
                    NewPullRequestSheet(model: model, head: head)
                case .account(let remote):
                    RemoteAccountSheet(model: model, remote: remote)
                }
            }
    }
}

/// Publish to a service, as menus offer it: one item per service an
/// account is signed in to, or one that leads to signing in.
struct PublishMenuItems: View {
    var model: RepositoryModel

    private var changes = AccountChangeCounter.shared

    init(model: RepositoryModel) {
        self.model = model
    }

    var body: some View {
        let _ = changes.count
        let kinds = HostingKind.allCases.filter { kind in
            ((try? AccountStore.shared.accounts()) ?? []).contains { $0.kind == kind && $0.usesService }
        }
        if kinds.isEmpty {
            Button("Publish to Hosting Service…", systemImage: "icloud.and.arrow.up") {
                model.hosting.sheet = .publish(nil)
            }
            .help("Make a repository for this one on GitHub, GitLab, Bitbucket, Gitea or Forgejo and push to it")
        } else {
            ForEach(kinds) { kind in
                Button("Publish to \(kind.shortTitle)…", systemImage: "icloud.and.arrow.up") {
                    model.hosting.sheet = .publish(kind)
                }
                .help("Make a repository for this one on \(kind.title), add it as a remote and push the current branch")
            }
        }
    }
}

/// Chooses the account a remote uses: its host's default, or another.
struct RemoteAccountSheet: View {
    var model: RepositoryModel
    var remote: String

    @Environment(\.dismiss) private var dismiss
    @State private var choice: UUID?
    @State private var isAdding = false
    private var changes = AccountChangeCounter.shared

    init(model: RepositoryModel, remote: String) {
        self.model = model
        self.remote = remote
    }

    private var url: String? {
        model.snapshot?.remotes.first { $0.name == remote }?.url
    }

    private var hosted: HostedRepository? {
        url.flatMap(HostedRepository.init(remoteURL:))
    }

    var body: some View {
        let _ = changes.count
        let host = hosted?.host ?? ""
        let accounts = AccountStore.shared.accounts(forHost: host)
        let fallback = AccountStore.shared.defaultAccount(forHost: host)
        SheetStack("Account") {
            Form {
                SheetTitleSection()
                Section {
                    Picker("Account", selection: $choice) {
                        Text("Default" + (fallback.map { " (\($0.login))" } ?? "")).tag(UUID?.none)
                        ForEach(accounts) { account in
                            Text(account.login + (account.name.map { " – \($0)" } ?? "")).tag(UUID?.some(account.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Button("Add Account…", systemImage: "plus") { isAdding = true }
                } header: {
                    Text("“\(remote)” on \(host)")
                } footer: {
                    Text("The account git uses over HTTPS for this repository, and the one its pull requests are read and written with.")
                }
            }
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let url { AccountStore.shared.setAccount(choice, forRemoteURL: url) }
                        model.hosting.pullRequests.invalidate()
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
        .onAppear {
            choice = hosted.flatMap { AccountStore.shared.chosenAccountID(for: $0) }
        }
        .sheet(isPresented: $isAdding) {
            SignInSheet(initialKind: hosted.flatMap { HostingKind($0.kind) } ?? .github, initialHost: host) { account in
                choice = account.id
            }
        }
    }
}
