import SwiftUI
import TwigShared
import WidgetKit

/// Repositories with commits not pushed or changes not committed, from the
/// status file the app writes. The app reloads the widget each time it
/// writes the file, so the timeline only has to show what is there.
struct UnpushedChangesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UnpushedChanges", provider: UnpushedChangesProvider()) { entry in
            UnpushedChangesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Unpushed Changes")
        .description("Repositories with commits to push or changes to commit.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UnpushedChangesEntry: TimelineEntry {
    var date: Date
    var changes: UnpushedChanges
}

struct UnpushedChangesProvider: TimelineProvider {
    func placeholder(in context: Context) -> UnpushedChangesEntry {
        UnpushedChangesEntry(date: .now, changes: UnpushedChanges(Self.sample))
    }

    func getSnapshot(in context: Context, completion: @escaping (UnpushedChangesEntry) -> Void) {
        let saved = SharedStatusStore.load()
        // The widget gallery shows the sample until the app has written anything.
        let summaries = context.isPreview && saved.isEmpty ? Self.sample : saved
        completion(UnpushedChangesEntry(date: .now, changes: UnpushedChanges(summaries)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnpushedChangesEntry>) -> Void) {
        let entry = UnpushedChangesEntry(date: .now, changes: UnpushedChanges(SharedStatusStore.load()))
        // A late look in case a reload was missed; the app's reloads do the real work.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }

    static let sample: [RepositoryStatusSummary] = [
        RepositoryStatusSummary(
            id: UUID(), name: "Horizontal", branch: "main", ahead: 3, behind: 0,
            hasUncommittedChanges: true, updated: .now
        ),
        RepositoryStatusSummary(
            id: UUID(), name: "Notes", branch: "draft", ahead: 1, behind: 2,
            hasUncommittedChanges: false, updated: .now.addingTimeInterval(-600)
        )
    ]
}

struct UnpushedChangesView: View {
    var entry: UnpushedChangesEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.changes.isEmpty {
            EmptyStateView()
        } else if family == .systemSmall {
            SmallView(changes: entry.changes)
        } else {
            ListView(changes: entry.changes, limit: family == .systemLarge ? UnpushedChanges.limit : 2)
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.title)
                .foregroundStyle(.green)
            Text("Everything is pushed")
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The count, and the first one or two by name. A small widget is one
/// tap target, so it opens the first.
private struct SmallView: View {
    var changes: UnpushedChanges

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(changes.total)")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Text(changes.total == 1 ? "repository to push" : "repositories to push")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            ForEach(changes.repositories.prefix(2)) { summary in
                Text(summary.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(changes.repositories.first.map { TwigLink.openRepository($0.id).url })
    }
}

private struct ListView: View {
    var changes: UnpushedChanges
    var limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Unpushed Changes")
                    .font(.headline)
                Spacer()
                Text("\(changes.total)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            ForEach(changes.repositories.prefix(limit)) { summary in
                Link(destination: TwigLink.openRepository(summary.id).url) {
                    RowView(summary: summary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RowView: View {
    var summary: RepositoryStatusSummary

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let branch = summary.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if summary.ahead > 0 {
                    Label("\(summary.ahead)", systemImage: "arrow.up")
                }
                if summary.behind > 0 {
                    Label("\(summary.behind)", systemImage: "arrow.down")
                }
                if summary.hasUncommittedChanges {
                    Image(systemName: "pencil")
                        .accessibilityLabel("Uncommitted changes")
                }
            }
            .font(.caption.monospacedDigit())
            .labelStyle(CompactLabelStyle())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(summary.unpushedDescription)
    }
}

/// An icon and a number, tight together.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 1) {
            configuration.icon
            configuration.title
        }
    }
}
