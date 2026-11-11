import SwiftUI

/// Where cloning and publishing take a repository's address from.
enum HostingPreferences {
    static let prefersSSHKey = "hosting.prefersSSH"
}

/// Publishes the repository: makes one on an account's service, adds it
/// as a remote and pushes the current branch to it.
struct PublishSheet: View {
    var model: RepositoryModel
    /// The service chosen in the menu, or `nil` for any.
    var kind: HostingKind?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(HostingPreferences.prefersSSHKey) private var prefersSSH = false
    @State private var accountID: UUID?
    @State private var owners: [HostingOwner] = []
    @State private var ownerID: String?
    @State private var name = ""
    @State private var description = ""
    @State private var isPrivate = true
    @State private var isLoadingOwners = false
    @State private var isPublishing = false
    @State private var failure: String?
    @State private var isAdding = false
    private var changes = AccountChangeCounter.shared

    init(model: RepositoryModel, kind: HostingKind?) {
        self.model = model
        self.kind = kind
    }

    private var accounts: [HostingAccount] {
        _ = changes.count
        return ((try? AccountStore.shared.accounts()) ?? []).filter { $0.usesService && (kind == nil || $0.kind == kind) }
    }

    private var account: HostingAccount? {
        accounts.first { $0.id == accountID } ?? accounts.first
    }

    var body: some View {
        NavigationStack {
            Form {
                if accounts.isEmpty {
                    Section {
                        Text("Sign in to \(kind?.title ?? "a hosting service") to publish this repository there.")
                        Button("Add Account…", systemImage: "plus") { isAdding = true }
                    }
                } else {
                    Section {
                        Picker("Account", selection: Binding { account?.id } set: { accountID = $0 }) {
                            ForEach(accounts) { account in
                                Text("\(account.login) on \(account.host)").tag(UUID?.some(account.id))
                            }
                        }
                        Picker("Owner", selection: $ownerID) {
                            ForEach(owners) { owner in
                                Text(owner.isUser ? "\(owner.displayName) (you)" : owner.displayName).tag(String?.some(owner.id))
                            }
                        }
                        .disabled(owners.isEmpty)
                        .overlay(alignment: .trailing) {
                            if isLoadingOwners { ProgressView().controlSize(.small).padding(.trailing, 24) }
                        }
                        TextField("Name", text: $name)
                            .autocorrectionDisabled()
                            .noAutocapitalization()
                        TextField("Description", text: $description, prompt: Text("Optional"))
                        Toggle("Private", isOn: $isPrivate)
                    } footer: {
                        Text(isPrivate ? "Only people you give access can see it." : "Anyone can see it.")
                    }
                    Section {
                        Picker("Address", selection: $prefersSSH) {
                            Text("HTTPS").tag(false)
                            Text("SSH").tag(true)
                        }
                    } footer: {
                        Text(footer)
                    }
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isPublishing)
            .navigationTitle(kind.map { "Publish to \($0.shortTitle)" } ?? "Publish")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(isPublishing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPublishing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Publish") { publish() }
                            .disabled(!canPublish)
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .interactiveDismissDisabled(isPublishing)
        .onAppear {
            if name.isEmpty { name = Self.suggestedName(model.name) }
        }
        .task(id: account?.id) { await loadOwners() }
        .sheet(isPresented: $isAdding) {
            SignInSheet(initialKind: kind ?? .github) { accountID = $0.id }
        }
    }

    private var footer: String {
        let branch = model.currentBranch.map { "“\($0.name)”" }
        let remote = model.remoteNames.contains("origin") ? "a new remote" : "“origin”"
        return "Twig adds the new repository as \(remote)"
            + (branch.map { " and pushes \($0) to it, tracking it." } ?? ". There are no commits to push yet.")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var canPublish: Bool {
        account != nil && owners.contains { $0.id == ownerID } && !trimmedName.isEmpty
            && !trimmedName.contains("/") && !trimmedName.contains(" ")
    }

    /// The folder's name as a repository name: no spaces.
    static func suggestedName(_ folder: String) -> String {
        folder.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }

    private func loadOwners() async {
        guard let account else { return }
        owners = []
        failure = nil
        isLoadingOwners = true
        defer { isLoadingOwners = false }
        do {
            owners = try await account.service().owners()
            if !owners.contains(where: { $0.id == ownerID }) { ownerID = owners.first?.id }
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }

    private func publish() {
        guard let account, let owner = owners.first(where: { $0.id == ownerID }) else { return }
        let draft = NewRepositoryDraft(
            owner: owner, name: trimmedName, description: description.trimmingCharacters(in: .whitespaces),
            isPrivate: isPrivate
        )
        isPublishing = true
        failure = nil
        Task {
            defer { isPublishing = false }
            do {
                let published = try await model.createPublishedRemote(draft, on: account, preferSSH: prefersSSH)
                dismiss()
                await model.pushPublished(published)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
