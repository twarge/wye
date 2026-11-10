import GitKit
import SwiftUI

/// Lists, adds and removes the rules in `.gitignore` and in this clone's
/// own exclude file.
struct IgnoreRulesSheet: View {
    var model: RepositoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var file = IgnoreFile.shared
    @State private var patterns: [String] = []
    @State private var newPattern = ""
    /// Tracked files a new rule matches, offered to stop tracking.
    @State private var nowIgnoredTracked: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Rules In", selection: $file) {
                        Text(".gitignore").tag(IgnoreFile.shared)
                        Text("This Clone Only").tag(IgnoreFile.local)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(file == .shared
                        ? "The .gitignore at the top of the repository. Committing it shares the rules with everyone."
                        : "Kept in .git/info/exclude, which is never committed.")
                }

                Section("Rules") {
                    if patterns.isEmpty {
                        Text("No rules yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(patterns, id: \.self) { pattern in
                        HStack {
                            Text(pattern)
                                .font(.code)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                Task { await remove([pattern]) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Remove this rule")
                        }
                    }
                    .onDelete { offsets in
                        let removed = offsets.map { patterns[$0] }
                        Task { await remove(removed) }
                    }
                }

                Section {
                    HStack {
                        TextField("Pattern, such as *.log or /build/", text: $newPattern)
                            .font(.code)
                            .autocorrectionDisabled()
                            .noAutocapitalization()
                            .onSubmit { Task { await add() } }
                        Button("Add") { Task { await add() } }
                            .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Add a Rule")
                } footer: {
                    Text("A leading / anchors a rule to the top of the repository, a trailing / matches only folders, and * matches anything but /.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ignore Rules")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetMinimumSize(width: 460, height: 480)
        .task(id: file) {
            await load()
        }
        .confirmationDialog(
            "Stop Tracking the \(nowIgnoredTracked.count.formatted()) Tracked Files the Rule Matches?",
            isPresented: Binding { !nowIgnoredTracked.isEmpty } set: { if !$0 { nowIgnoredTracked = [] } },
            titleVisibility: .visible
        ) {
            Button("Stop Tracking", role: .destructive) {
                let paths = nowIgnoredTracked
                Task { await model.stopTracking(paths) }
            }
        } message: {
            Text("git keeps showing changes to tracked files, even ignored ones. They stay on disk as they are, but leave the index: the next commit removes them from the repository, and from other working copies when they pull it.")
        }
    }

    private func load() async {
        do {
            patterns = try await model.repository.ignorePatterns(in: file)
        } catch {
            model.error = PresentedError(error)
        }
    }

    private func add() async {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        nowIgnoredTracked = await model.ignore(pattern, in: file, offeringToStopTracking: false)
        newPattern = ""
        await load()
    }

    private func remove(_ removed: [String]) async {
        let file = file
        await model.perform { try await $0.removeIgnorePatterns(Set(removed), from: file) }
        await load()
    }
}
