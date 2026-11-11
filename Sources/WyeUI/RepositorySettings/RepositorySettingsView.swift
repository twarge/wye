import GitKit
import SwiftUI

/// One repository's own settings: its author, how it pulls, its remotes,
/// and its git configuration. Reached from the Repository menu and the
/// Working Copy row's menu.
struct RepositorySettingsView: View {
    @Bindable var model: RepositoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var settings: RepositorySettingsModel
    @State private var addingRemote = false

    init(model: RepositoryModel) {
        self.model = model
        _settings = State(initialValue: RepositorySettingsModel(model: model))
    }

    var body: some View {
        NavigationStack {
            Form {
                AuthorSection(settings: settings)
                PullSection(model: model, settings: settings)
                PushSection(model: model)
                remotesSection
                IssueTrackerSection(interface: model.interface)
                Section {
                    NavigationLink {
                        ConfigurationEditorView(settings: settings)
                    } label: {
                        LabeledContent("Git Configuration") {
                            Text("^[\(settings.localEntries.count) entry](inflect: true)")
                        }
                    }
                } footer: {
                    Text("Every setting in this repository’s .git/config, to add to, change and remove.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("\(model.name) Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $addingRemote) {
                RemoteEditor(model: model, subject: .new)
            }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 480, idealHeight: 640)
        .task { await settings.reload() }
        // The repository window's alert cannot show while this sheet is up.
        .alert(for: $model.error)
    }

    private var remotesSection: some View {
        Section {
            ForEach(model.snapshot?.remotes ?? []) { remote in
                NavigationLink {
                    RemoteSettingsView(model: model, settings: settings, remote: remote)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(remote.name)
                        Text(remote.url ?? "No URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Button("Add Remote…", systemImage: "plus") { addingRemote = true }
        } header: {
            Text("Remotes")
        } footer: {
            Text("Each remote’s URLs, the references it fetches and pushes, and its default branch.")
        }
    }
}

// MARK: Author

private struct AuthorSection: View {
    var settings: RepositorySettingsModel

    @State private var name = ""
    @State private var email = ""
    @State private var hasLoaded = false

    var body: some View {
        let app = GitEnvironment.globalIdentity()
        Section {
            // Author profiles: a picker of the profiles kept in Settings
            // goes here, filling in the two fields below.
            TextField("Name", text: $name, prompt: Text(app?.name ?? "Name"))
                .textContentType(.name)
            TextField("Email", text: $email, prompt: Text(app?.email ?? "Email"))
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .noAutocapitalization()
        } header: {
            Text("Author")
        } footer: {
            Text("Recorded as the author of commits made in this repository, in its own configuration. "
                 + "Leave both empty to use the author from Settings.")
        }
        .onChange(of: settings.isLoaded, initial: true) {
            guard settings.isLoaded, !hasLoaded else { return }
            hasLoaded = true
            name = settings.localValue("user.name") ?? ""
            email = settings.localValue("user.email") ?? ""
        }
        .task(id: [name, email]) {
            guard hasLoaded else { return }
            // Once typing pauses, not on every key.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await settings.saveAuthor(name: name, email: email)
        }
    }
}

// MARK: Pull

private struct PullSection: View {
    var model: RepositoryModel
    var settings: RepositorySettingsModel

    var body: some View {
        Section {
            Picker("Default Remote", selection: Binding {
                model.chosenDefaultRemote ?? ""
            } set: { remote in
                RepositoryPreferences.setDefaultRemote(remote.isEmpty ? nil : remote, for: model.id)
                // Nothing observable changed; the menus read it again on refresh.
                Task { await model.refresh() }
            }) {
                Text("Automatic").tag("")
                ForEach(model.remoteNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Picker("Pull By", selection: Binding {
                settings.pullMode
            } set: { mode in
                Task { await settings.setPullMode(mode) }
            }) {
                Text("App Setting (\(RemotePreferences.pullMode.title))").tag(PullMode?.none)
                ForEach(PullMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(PullMode?.some(mode))
                }
            }
            Picker("Stash Local Changes", selection: Binding {
                RepositoryPreferences.autostash(for: model.id)
            } set: { policy in
                RepositoryPreferences.setAutostash(policy, for: model.id)
                Task { await model.refresh() }
            }) {
                Text("App Setting (\(RemotePreferences.autostash.title))").tag(AutostashPolicy?.none)
                ForEach(AutostashPolicy.allCases) { policy in
                    Text(policy.title).tag(AutostashPolicy?.some(policy))
                }
            }
        } header: {
            Text("Fetch and Pull")
        } footer: {
            Text("The default remote is fetched and published to when the current branch’s upstream doesn’t say. "
                 + "Pull By is kept in the repository’s configuration as pull.rebase and pull.ff, which git reads too.")
        }
        // Read by the pickers' bindings, so they show the saved choice after a change.
        .id(model.revision)
    }
}

// MARK: Push

private struct PushSection: View {
    var model: RepositoryModel

    var body: some View {
        Section {
            Picker("Push All Tags", selection: Binding {
                RepositoryPreferences.pushesAllTags(for: model.id)
            } set: { pushes in
                RepositoryPreferences.setPushesAllTags(pushes, for: model.id)
                Task { await model.refresh() }
            }) {
                Text("App Setting (\(PushPreferences.pushesAllTags() ? "On" : "Off"))").tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
        } header: {
            Text("Push")
        } footer: {
            Text("Whether pushing a branch also sends every tag in this repository to the same remote.")
        }
        // Read by the picker's binding, so it shows the saved choice after a change.
        .id(model.revision)
    }
}
