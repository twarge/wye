import GitKit
import SwiftUI

/// The activity log: a window of its own on macOS, a sheet on iOS.
struct ActivityView: View {
    /// Shows a Done button, for the sheet.
    var showsDone = false

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var log: ActivityLog { .shared }

    var body: some View {
        NavigationStack {
            List(filtered) { entry in
                ActivityRow(entry: entry)
            }
            .overlay {
                if log.entries.isEmpty {
                    ContentUnavailableView(
                        "No Activity", systemImage: "list.bullet.clipboard",
                        description: Text("Fetches, pulls, pushes, commits and every other operation Wye runs this session are listed here.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Operation, repository or error")
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", systemImage: "trash") { log.clear() }
                        .disabled(log.entries.allSatisfy { $0.outcome == .running })
                        .help("Clear the finished operations from the log")
                }
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .sheetMinimumSize(width: 420, height: 300)
        .onAppear { log.markSeen() }
        .onChange(of: log.unseenFailures) { log.markSeen() }
    }

    private var filtered: [ActivityEntry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return log.entries }
        return log.entries.filter { entry in
            entry.title.localizedStandardContains(query)
                || entry.repository?.localizedStandardContains(query) == true
                || entry.failure?.localizedStandardContains(query) == true
        }
    }
}

private struct ActivityRow: View {
    var entry: ActivityEntry

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(.headline)
                    if entry.isBackground {
                        Text("Automatic")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(entry.started, format: .dateTime.hour().minute().second())
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let failure = entry.failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if !entry.said.isEmpty {
                    Text(entry.said.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityLabel("The server said: \(entry.said.joined(separator: ". "))")
                }
            }
        } icon: {
            icon
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.outcome {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    /// Repository, how long it took, and what moved over the network.
    private var details: String {
        var parts: [String] = []
        if let repository = entry.repository { parts.append(repository) }
        switch entry.outcome {
        case .running: parts.append("Running")
        case .cancelled: parts.append("Cancelled")
        case .succeeded, .failed: break
        }
        if let duration = entry.duration {
            parts.append(Duration.seconds(duration).formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2)))
        }
        if let transfer = entry.transfer, transfer.total > 0 || transfer.bytes > 0 {
            var text = "\(transfer.completed) of \(transfer.total) objects"
            if transfer.bytes > 0 {
                text += ", " + transfer.bytes.formatted(.byteCount(style: .file))
            }
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }
}

extension ActivityEntry {
    var failure: String? {
        if case .failed(let message) = outcome { message } else { nil }
    }
}
