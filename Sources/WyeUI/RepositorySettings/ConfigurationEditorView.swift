import GitKit
import SwiftUI

/// The repository's own git configuration as a list of entries, to search,
/// add to, change and remove, with what Wye sets for every repository below.
struct ConfigurationEditorView: View {
    var settings: RepositorySettingsModel

    @State private var query = ""
    @State private var editing: EditorSubject?
    @State private var removing: ConfigurationEdit.IndexedEntry?

    var body: some View {
        List {
            Section {
                ForEach(filtered(settings.localEntries)) { item in
                    Button {
                        editing = .existing(item)
                    } label: {
                        EntryRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit…", systemImage: "pencil") { editing = .existing(item) }
                        Button("Add Another Value…", systemImage: "plus") { editing = .new(name: item.entry.name) }
                        Divider()
                        Button("Remove…", systemImage: "trash", role: .destructive) { removing = item }
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { removing = item }
                    }
                }
                if settings.localEntries.isEmpty, settings.isLoaded {
                    Text("No entries").foregroundStyle(.secondary)
                }
            } header: {
                Text("This Repository")
            }

            Section {
                ForEach(filtered(settings.appEntries)) { item in
                    EntryRow(item: item)
                        .foregroundStyle(.secondary)
                }
                if settings.appEntries.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
            } header: {
                Text("Applied by Wye to Every Repository")
            } footer: {
                Text("Read only: the author and other settings from Wye’s Settings, which apply where this repository sets nothing itself. "
                     + "Wye never reads or writes the .gitconfig in your home folder; the App Store sandbox keeps it out of reach.")
            }
        }
        .searchable(text: $query, prompt: "Key or value")
        .navigationTitle("Git Configuration")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Entry", systemImage: "plus") { editing = .new(name: "") }
            }
        }
        .sheet(item: $editing) { subject in
            EntryEditor(settings: settings, subject: subject)
        }
        .confirmationDialog(
            "Remove \(removing?.entry.name ?? "")?",
            isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
            titleVisibility: .visible,
            presenting: removing
        ) { item in
            Button("Remove Entry", role: .destructive) {
                Task {
                    let values = ConfigurationEdit.values(settings.values(of: item.entry.name), replacingAt: item.index, with: nil)
                    await settings.setValues(values, for: item.entry.name)
                }
            }
        } message: { item in
            Text(item.count > 1
                 ? "Removes the value “\(item.entry.value)”. The key’s other \(item.count - 1 == 1 ? "value stays" : "\(item.count - 1) values stay")."
                 : "Removes the setting from this repository’s configuration. git then uses the default, or the value Wye applies.")
        }
    }

    private func filtered(_ entries: [ConfigurationEntry]) -> [ConfigurationEdit.IndexedEntry] {
        let all = ConfigurationEdit.indexed(entries)
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.entry.name.localizedStandardContains(query) || $0.entry.value.localizedStandardContains(query) }
    }
}

private struct EntryRow: View {
    var item: ConfigurationEdit.IndexedEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.entry.name)
                    .font(.code)
                if item.count > 1 {
                    Text("\(item.index + 1) of \(item.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("This key has several values; git uses all of them, or the last")
                }
            }
            Text(item.entry.value.isEmpty ? "(empty)" : item.entry.value)
                .font(.smallCode)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

private enum EditorSubject: Identifiable {
    /// A new value, for this key if it is not empty.
    case new(name: String)
    case existing(ConfigurationEdit.IndexedEntry)

    var id: String {
        switch self {
        case .new(let name): "new:\(name)"
        case .existing(let item): item.id
        }
    }
}

private struct EntryEditor: View {
    var settings: RepositorySettingsModel
    var subject: EditorSubject

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    /// For a key that already has values: add this one beside them, or replace them.
    @State private var addsValue = true

    var body: some View {
        SheetStack(isNew ? "New Entry" : "Edit Entry") {
            Form {
                SheetTitleSection()
                Section {
                    TextField("Key", text: $name, prompt: Text("section.name"))
                        .font(.code)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                    TextField("Value", text: $value, axis: .vertical)
                        .font(.code)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                } footer: {
                    if !trimmedName.isEmpty, normalizedName == nil {
                        Text("Keys look like section.name or section.subsection.name: letters, digits and hyphens, the name starting with a letter.")
                            .foregroundStyle(.red)
                    }
                }
                if isNew, let normalizedName, !settings.values(of: normalizedName).isEmpty {
                    Section {
                        Picker("This Key Has Values", selection: $addsValue) {
                            Text("Add Another Value").tag(true)
                            Text("Replace Them").tag(false)
                        }
                        .pickerStyle(.inline)
                    } footer: {
                        Text("Some keys, such as remote fetch refspecs, take several values; most use only the last.")
                    }
                }
            }
            .groupedFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { save() }
                        .disabled(normalizedName == nil)
                }
            }
        }
        .sheetMinimumSize(width: 400)
        .onAppear {
            switch subject {
            case .new(let name): self.name = name
            case .existing(let item):
                name = item.entry.name
                value = item.entry.value
            }
        }
    }

    private var isNew: Bool {
        if case .new = subject { true } else { false }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var normalizedName: String? {
        try? Repository.normalizedConfigurationName(trimmedName)
    }

    private func save() {
        guard let name = normalizedName else { return }
        let value = value
        let subject = subject
        let addsValue = addsValue
        dismiss()
        Task {
            switch subject {
            case .new:
                let existing = settings.values(of: name)
                await settings.setValues(addsValue ? existing + [value] : [value], for: name)
            case .existing(let item) where item.entry.name == name:
                let values = ConfigurationEdit.values(settings.values(of: name), replacingAt: item.index, with: value)
                await settings.setValues(values, for: name)
            case .existing(let item):
                // Renamed: the value leaves its old key and joins the new one.
                let old = ConfigurationEdit.values(settings.values(of: item.entry.name), replacingAt: item.index, with: nil)
                await settings.setValues(old, for: item.entry.name)
                await settings.setValues(settings.values(of: name) + [value], for: name)
            }
        }
    }
}
