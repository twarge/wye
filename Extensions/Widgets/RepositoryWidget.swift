import AppIntents
import SwiftUI
import WidgetKit
import WyeShared

/// One repository, chosen when the widget is edited: its branch, what it
/// has to push, pull and commit, and buttons to fetch and pull it.
struct RepositoryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "Repository", intent: RepositoryWidgetConfiguration.self, provider: RepositoryWidgetProvider()
        ) { entry in
            RepositoryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Repository")
        .description("One repository’s branch and status, with Fetch and Pull.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryRectangular]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

struct RepositoryWidgetEntry: TimelineEntry {
    var date: Date
    /// The repository to show; `nil` when none is chosen or it is gone.
    var summary: RepositoryStatusSummary?
    /// Whether a repository was chosen at all, to tell "pick one" from "gone".
    var isConfigured: Bool
}

struct RepositoryWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RepositoryWidgetEntry {
        RepositoryWidgetEntry(date: .now, summary: UnpushedChangesProvider.sample[0], isConfigured: true)
    }

    func snapshot(for configuration: RepositoryWidgetConfiguration, in context: Context) async -> RepositoryWidgetEntry {
        let entry = entry(for: configuration)
        // The widget gallery shows the sample until one is chosen.
        if context.isPreview, entry.summary == nil { return placeholder(in: context) }
        return entry
    }

    func timeline(for configuration: RepositoryWidgetConfiguration, in context: Context) async -> Timeline<RepositoryWidgetEntry> {
        // A late look in case a reload was missed; the app's reloads do the real work.
        Timeline(entries: [entry(for: configuration)], policy: .after(.now.addingTimeInterval(3600)))
    }

    private func entry(for configuration: RepositoryWidgetConfiguration) -> RepositoryWidgetEntry {
        let saved = SharedStatusStore.load()
        guard let chosen = configuration.repository else {
            // With one repository there is nothing to choose.
            return RepositoryWidgetEntry(date: .now, summary: saved.count == 1 ? saved.first : nil, isConfigured: saved.count == 1)
        }
        return RepositoryWidgetEntry(date: .now, summary: saved.first { $0.id == chosen.id }, isConfigured: true)
    }
}

struct RepositoryWidgetView: View {
    var entry: RepositoryWidgetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let summary = entry.summary {
            content(summary)
                .widgetURL(WyeLink.openRepository(summary.id).url)
        } else {
            VStack(spacing: 6) {
                Image(systemName: entry.isConfigured ? "questionmark.folder" : "folder.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(entry.isConfigured ? "Repository not found" : "Edit the widget to choose a repository")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ summary: RepositoryStatusSummary) -> some View {
        if family == .systemSmall || family == .systemMedium {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.name)
                    .font(.headline)
                    .lineLimit(1)
                if let branch = summary.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                StatusCounts(summary: summary)
                Spacer(minLength: 2)
                HStack(spacing: 8) {
                    Button(intent: WidgetFetchIntent(repository: summary.id)) {
                        Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if summary.behind > 0 || family == .systemMedium {
                        Button(intent: WidgetPullIntent(repository: summary.id)) {
                            Label("Pull", systemImage: "arrow.down")
                        }
                        .disabled(summary.behind == 0)
                    }
                }
                .labelStyle(family == .systemSmall ? AnyWidgetLabelStyle.iconOnly : .titleAndIcon)
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(summary.branch ?? "Detached")
                    .font(.caption)
                    .lineLimit(1)
                Text(description(summary))
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func description(_ summary: RepositoryStatusSummary) -> String {
        let text = summary.unpushedDescription
        return text.isEmpty ? "Up to date" : text
    }
}

/// What there is to push, pull and commit, or that there is nothing.
private struct StatusCounts: View {
    var summary: RepositoryStatusSummary

    var body: some View {
        HStack(spacing: 8) {
            if summary.ahead > 0 {
                Label("\(summary.ahead)", systemImage: "arrow.up")
            }
            if summary.behind > 0 {
                Label("\(summary.behind)", systemImage: "arrow.down")
            }
            if summary.hasUncommittedChanges {
                Label("Changes", systemImage: "pencil")
            }
            if summary.ahead == 0, summary.behind == 0, !summary.hasUncommittedChanges {
                Label("Up to date", systemImage: "checkmark.circle")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.unpushedDescription.isEmpty ? "Up to date" : summary.unpushedDescription)
    }
}

/// Icon only where there is no room for a title.
private enum AnyWidgetLabelStyle: LabelStyle {
    case iconOnly
    case titleAndIcon

    func makeBody(configuration: Configuration) -> some View {
        switch self {
        case .iconOnly: configuration.icon
        case .titleAndIcon:
            HStack(spacing: 3) {
                configuration.icon
                configuration.title
            }
        }
    }
}
