import GitKit
import SwiftUI

/// The subject's length once it nears the soft limit: orange past it, red
/// past the hard one.
struct SubjectLengthMarker: View {
    var subject: String

    var body: some View {
        let preferences = CommitPreferences.shared
        let count = subject.trimmingCharacters(in: .whitespaces).count
        let level = preferences.classify(subject)
        // Out of the way until it matters.
        let showsFrom = preferences.softLimit > 0 ? preferences.softLimit - 10 : preferences.hardLimit - 10
        if (preferences.softLimit > 0 || preferences.hardLimit > 0), count > max(0, showsFrom) {
            Text(count.formatted())
                .font(.caption.monospacedDigit().weight(level == .fine ? .regular : .semibold))
                .foregroundStyle(color(level))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color(level).opacity(level == .fine ? 0 : 0.15), in: .capsule)
                .help(help(level, preferences: preferences))
                .accessibilityLabel("\(count) characters")
                .accessibilityValue(help(level, preferences: preferences))
        }
    }

    private func color(_ level: SubjectLength) -> Color {
        switch level {
        case .fine: .secondary
        case .long: .orange
        case .tooLong: .red
        }
    }

    private func help(_ level: SubjectLength, preferences: CommitPreferences) -> String {
        switch level {
        case .fine: "Subjects read best under \(preferences.softLimit > 0 ? preferences.softLimit : preferences.hardLimit) characters"
        case .long: "Longer than \(preferences.softLimit) characters: a shorter subject reads better in logs"
        case .tooLong: "Longer than \(preferences.hardLimit) characters: most tools cut it off"
        }
    }
}

/// Starts the message from a template or from an earlier commit's message.
struct MessageMenu: View {
    var model: RepositoryModel

    @State private var recent: [String] = []
    @State private var repositoryTemplate: String?
    @State private var pending: Pending?

    /// A message waiting to replace what the composer holds.
    private struct Pending: Identifiable {
        var message: String
        var isTemplate: Bool
        var id: String { message }
    }

    var body: some View {
        let templates = CommitPreferences.shared.templates
        Menu {
            if repositoryTemplate != nil || !templates.isEmpty {
                Section("Templates") {
                    if let repositoryTemplate {
                        Button("Repository Template") { use(repositoryTemplate, isTemplate: true) }
                    }
                    ForEach(templates) { template in
                        Button(template.name.isEmpty ? "Untitled" : template.name) {
                            use(template.text, isTemplate: true)
                        }
                    }
                }
            }
            Section("Recent Messages") {
                if recent.isEmpty {
                    Text("No Earlier Messages")
                }
                ForEach(recent, id: \.self) { message in
                    Button(CommitMessageText.summary(message)) { use(message, isTemplate: false) }
                }
            }
        } label: {
            Label("Messages", systemImage: "text.badge.plus")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Start from a template or an earlier message")
        .task(id: model.snapshot?.head) {
            recent = await model.recentCommitMessages()
            repositoryTemplate = await model.repositoryCommitTemplate()
        }
        .confirmationDialog(
            "Replace the Message You Are Writing?",
            isPresented: Binding { pending != nil } set: { if !$0 { pending = nil } },
            titleVisibility: .visible,
            presenting: pending
        ) { pending in
            Button("Replace Message", role: .destructive) {
                model.useMessage(pending.message, isTemplate: pending.isTemplate)
            }
        } message: { _ in
            Text("The subject and description written so far are replaced.")
        }
    }

    private func use(_ message: String, isTemplate: Bool) {
        let isEmpty = model.workingCopy.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.workingCopy.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            model.useMessage(message, isTemplate: isTemplate)
        } else {
            pending = Pending(message: message, isTemplate: isTemplate)
        }
    }
}
