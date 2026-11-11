import GitKit
import SwiftUI

/// One remote's settings: name, URLs, refspecs and default branch, saved together.
struct RemoteSettingsView: View {
    var model: RepositoryModel
    var settings: RepositorySettingsModel
    var remote: Remote

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    /// Empty to push to the fetch URL.
    @State private var pushURL = ""
    @State private var fetchRefspecs: [RefspecRow] = []
    @State private var pushRefspecs: [RefspecRow] = []
    /// A branch's short name; empty for none.
    @State private var defaultBranch = ""
    @State private var saved: Saved?

    /// What was read, to save only what changed.
    private struct Saved {
        var pushURL: String
        var fetch: [String]
        var push: [String]
        var defaultBranch: String
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                TextField("URL", text: $url, prompt: Text("https://example.com/owner/project.git"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                TextField("Push URL", text: $pushURL, prompt: Text("Same as the URL"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
            } footer: {
                Text("A push URL only when pushes go somewhere other than fetches, such as your own copy of the project.")
            }

            RefspecList(title: "Fetch Refspecs", direction: .fetch, rows: $fetchRefspecs, example: "+refs/heads/*:refs/remotes/\(trimmed(name))/*")
            RefspecList(title: "Push Refspecs", direction: .push, rows: $pushRefspecs, example: "refs/heads/main:refs/heads/main")

            Section {
                Picker("Default Branch", selection: $defaultBranch) {
                    Text("None").tag("")
                    ForEach(branchNames, id: \.self) { branch in
                        Text(branch).tag(branch)
                    }
                }
            } footer: {
                Text("The branch the remote has checked out, as refs/remotes/\(remote.name)/HEAD records it. "
                     + "Only branches already fetched can be chosen.")
            }

            Section {
                Button("Save Changes") { save() }
                    .disabled(!canSave)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(remote.name)
        .task { await load() }
    }

    private var branchNames: [String] {
        var names = remote.branches.map(\.nameWithoutRemote).filter { $0 != "HEAD" }
        if !defaultBranch.isEmpty, !names.contains(defaultBranch) {
            names.append(defaultBranch)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var canSave: Bool {
        saved != nil && !trimmed(name).isEmpty && !trimmed(url).isEmpty
            && (fetchRefspecs + pushRefspecs).allSatisfy(\.isAcceptable)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        let repository = model.repository
        let name = remote.name
        do {
            let push = try await repository.pushURL(ofRemote: name) ?? ""
            let fetch = try await repository.refspecs(ofRemote: name, direction: .fetch)
            let pushSpecs = try await repository.refspecs(ofRemote: name, direction: .push)
            let head = try await repository.defaultBranch(ofRemote: name) ?? ""
            self.name = name
            url = remote.url ?? ""
            pushURL = push
            fetchRefspecs = fetch.map { RefspecRow(text: $0, direction: .fetch) }
            pushRefspecs = pushSpecs.map { RefspecRow(text: $0, direction: .push) }
            defaultBranch = head
            saved = Saved(pushURL: push, fetch: fetch, push: pushSpecs, defaultBranch: head)
        } catch {
            model.error = PresentedError(error)
        }
    }

    private func save() {
        guard let saved else { return }
        let remote = remote
        let (name, url, pushURL) = (trimmed(name), trimmed(url), trimmed(pushURL))
        let fetch = fetchRefspecs.map(\.trimmed).filter { !$0.isEmpty }
        let push = pushRefspecs.map(\.trimmed).filter { !$0.isEmpty }
        let defaultBranch = defaultBranch
        Task {
            // Refspecs and the default branch under the old name, before
            // any rename carries them over.
            if fetch != saved.fetch || push != saved.push || defaultBranch != saved.defaultBranch {
                await settings.change("Edit Remote") { repository in
                    if fetch != saved.fetch {
                        try await repository.setRefspecs(fetch, ofRemote: remote.name, direction: .fetch)
                    }
                    if push != saved.push {
                        try await repository.setRefspecs(push, ofRemote: remote.name, direction: .push)
                    }
                    if defaultBranch != saved.defaultBranch {
                        try await repository.setDefaultBranch(defaultBranch.isEmpty ? nil : defaultBranch, ofRemote: remote.name)
                    }
                }
            }
            if name != remote.name || url != remote.url ?? "" || pushURL != saved.pushURL {
                await model.editRemote(remote, name: name, url: url, pushURL: pushURL)
                await settings.reload()
            }
            if model.error == nil {
                dismiss()
            }
        }
    }
}

/// One refspec being edited.
struct RefspecRow: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var direction: RefspecDirection

    var trimmed: String {
        text.trimmingCharacters(in: .whitespaces)
    }

    /// Empty rows are dropped when saving; anything else must be one git reads.
    var isAcceptable: Bool {
        trimmed.isEmpty || Repository.isValidRefspec(trimmed, direction: direction)
    }
}

private struct RefspecList: View {
    var title: String
    var direction: RefspecDirection
    @Binding var rows: [RefspecRow]
    var example: String

    var body: some View {
        Section {
            ForEach($rows) { $row in
                HStack {
                    TextField("Refspec", text: $row.text, prompt: Text(example))
                        .font(.code)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                    if !row.isAcceptable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .help("Not a refspec git can read")
                            .accessibilityLabel("Not a valid refspec")
                    }
                    Button("Remove", systemImage: "minus.circle", role: .destructive) {
                        rows.removeAll { $0.id == row.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
            Button("Add Refspec", systemImage: "plus") {
                rows.append(RefspecRow(text: "", direction: direction))
            }
        } header: {
            Text(title)
        } footer: {
            if direction == .fetch {
                Text("Which of the remote’s references a fetch brings, and where they go here. A + updates them even when they don’t move forward.")
            } else {
                Text("What a plain push sends when no branch is named. With none, Wye pushes the current branch to its upstream.")
            }
        }
    }
}
