import SwiftUI

/// The issue trackers a repository's commit messages link to, beyond the
/// hosting service's own issues: a pattern for references and the page
/// each one opens.
struct IssueTrackerSection: View {
    var interface: RepositoryInterfaceState

    @State private var rows: [Row] = []
    @State private var hasLoaded = false

    private struct Row: Identifiable, Hashable {
        let id = UUID()
        var pattern: String
        var urlTemplate: String

        var tracker: IssueTracker { IssueTracker(pattern: pattern, urlTemplate: urlTemplate) }
        var isEmpty: Bool { urlTemplate.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        Section {
            ForEach($rows) { $row in
                VStack(alignment: .leading) {
                    HStack {
                        TextField("Pattern", text: $row.pattern, prompt: Text(IssueTracker.jiraPattern))
                            .font(.code)
                            .autocorrectionDisabled()
                            .noAutocapitalization()
                        if !row.isEmpty, !row.tracker.isValid {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .help("The pattern must be a regular expression and the address must contain $0 or a group such as $1")
                                .accessibilityLabel("Not valid")
                        }
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            rows.removeAll { $0.id == row.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    TextField("Address", text: $row.urlTemplate, prompt: Text("https://example.atlassian.net/browse/$0"))
                        .font(.code)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                }
            }
            Button("Add Issue Tracker", systemImage: "plus") {
                rows.append(Row(pattern: IssueTracker.jiraPattern, urlTemplate: ""))
            }
        } header: {
            Text("Issue Trackers")
        } footer: {
            Text("References in commit messages that match a pattern become links. In the address, $0 stands for the whole reference and $1, $2… for the pattern’s groups.")
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            rows = interface.issueTrackers.map { Row(pattern: $0.pattern, urlTemplate: $0.urlTemplate) }
        }
        .onChange(of: rows) {
            // Only the complete, valid ones; the rest wait until they are.
            let trackers = rows.filter { !$0.isEmpty && $0.tracker.isValid }.map(\.tracker)
            if trackers != interface.issueTrackers {
                interface.setIssueTrackers(trackers)
            }
        }
    }
}
