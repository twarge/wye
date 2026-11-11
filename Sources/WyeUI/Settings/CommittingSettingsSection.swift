import SwiftUI

/// The subject length markers and the app's commit message templates.
struct CommittingSettingsSection: View {
    @Bindable private var preferences = CommitPreferences.shared
    @State private var editing: CommitTemplate?

    var body: some View {
        Section {
            Picker("Mark Subjects Longer Than", selection: $preferences.softLimit) {
                ForEach(CommitPreferences.softLimitChoices, id: \.self) { limit in
                    Text(limit == 0 ? "Off" : "\(limit) Characters").tag(limit)
                }
            }
            Picker("Warn Past", selection: $preferences.hardLimit) {
                ForEach(CommitPreferences.hardLimitChoices, id: \.self) { limit in
                    Text(limit == 0 ? "Off" : "\(limit) Characters").tag(limit)
                }
            }
            ForEach(preferences.templates) { template in
                LabeledContent {
                    HStack {
                        Button("Edit", systemImage: "pencil") { editing = template }
                            .help("Edit this template")
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            preferences.templates.removeAll { $0.id == template.id }
                        }
                        .help("Remove this template")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                } label: {
                    Text(template.name.isEmpty ? "Untitled" : template.name)
                    Text(CommitMessageText.summary(template.text))
                }
            }
            Button("Add Template…", systemImage: "plus") {
                editing = CommitTemplate(name: "", text: "")
            }
        } header: {
            Text("Committing")
        } footer: {
            Text("Templates show in the composer’s message menu, with the repository’s own commit.template when it is inside the repository. Lines starting with # are left out.")
        }
        .sheet(item: $editing) { template in
            TemplateEditor(template: template) { saved in
                if let index = preferences.templates.firstIndex(where: { $0.id == saved.id }) {
                    preferences.templates[index] = saved
                } else {
                    preferences.templates.append(saved)
                }
            }
        }
    }
}

private struct TemplateEditor: View {
    @State var template: CommitTemplate
    var save: (CommitTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $template.name)
                Section("Message") {
                    TextEditor(text: $template.text)
                        .font(.code)
                        .frame(minHeight: 160)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(template)
                        dismiss()
                    }
                    .disabled(template.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .sheetMinimumSize(width: 420, height: 380)
    }
}
