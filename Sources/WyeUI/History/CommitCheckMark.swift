import GitKit
import SwiftUI

/// The mark on a commit whose checks ran: how they stand over every
/// hosting service that ran any. A click, or the pointer resting on it,
/// shows each of them.
struct CommitCheckMark: View {
    var commit: OID
    var status: CheckStatus
    /// How large the mark is beside the row's text.
    var scale: Image.Scale = .medium

    @Environment(CommitCheckStore.self) private var store: CommitCheckStore?
    @State private var isShown = false
    /// Shown by a click it stays until dismissed; shown by the pointer it
    /// goes when the pointer does.
    @State private var isPinned = false
    @State private var isPointerOverPopover = false
    /// The popover about to open or close as the pointer came or went.
    @State private var pending: Task<Void, Never>?

    var body: some View {
        Button {
            pending?.cancel()
            isPinned = true
            isShown = true
        } label: {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .imageScale(scale)
                .contentShape(.rect)
        }
        // Borderless, so that in a row only the mark takes the click.
        .buttonStyle(.borderless)
        .accessibilityLabel(status.summary)
        .onHover { pointerMoved(over: $0) }
        .popover(isPresented: $isShown) {
            if let store {
                CommitChecksPopover(store: store, commit: commit)
                    .onHover { isOver in
                        isPointerOverPopover = isOver
                        if !isOver { pointerMoved(over: false) }
                    }
            }
        }
        .onChange(of: isShown) {
            if !isShown {
                isPinned = false
                isPointerOverPopover = false
            }
        }
    }

    /// Opens the popover once the pointer has rested on the mark, and
    /// closes one opened that way a moment after the pointer has left
    /// both: long enough to cross from the mark into the popover.
    private func pointerMoved(over isOver: Bool) {
        pending?.cancel()
        if isOver {
            guard !isShown else { return }
            pending = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                isShown = true
            }
        } else if isShown, !isPinned {
            pending = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, !isPointerOverPopover, !isPinned else { return }
                isShown = false
            }
        }
    }
}

/// Every check of a commit, under the repository and the workflow or stage
/// it ran in, each a link to its page.
struct CommitChecksPopover: View {
    var store: CommitCheckStore
    var commit: OID

    var body: some View {
        let sections = store.sections(for: commit)
        let runs = sections.flatMap { $0.entry.runs ?? [] }
        let isListed = sections.contains { $0.entry.runs != nil }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let status = store.statuses[commit] {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.color)
                }
                Text(isListed ? runs.tally(overall: store.statuses[commit]) : store.statuses[commit]?.summary ?? "No checks")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(commit.abbreviated())
                    .font(.smallCode)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        if section.id != sections.first?.id {
                            Divider()
                                .padding(.vertical, 6)
                        }
                        CheckSectionRows(section: section, commit: commit)
                    }
                    if let failure = store.runFailures[commit] {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // As tall as its rows, until there are too many to show at once.
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 6) {
                if store.loadingRuns.contains(commit) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading…")
                } else if let listed = sections.compactMap(\.entry.runsFetchedAt).min() {
                    Text(listed.timeIntervalSinceNow > -60 ? "Read just now" : "Read \(listed.formatted(.relative(presentation: .named)))")
                }
                Spacer()
                Button("Read Again", systemImage: "arrow.clockwise") {
                    Task { await store.loadRuns(for: commit) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(store.loadingRuns.contains(commit))
                .help("Read the checks again")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(width: 340)
        // A popover on an iPhone too, not a sheet over the history.
        .presentationCompactAdaptation(.popover)
        .task { await store.loadRuns(for: commit) }
    }
}

/// One repository's checks of a commit: the repository, then its checks
/// under their workflows or stages.
private struct CheckSectionRows: View {
    var section: CommitCheckStore.Section
    var commit: OID

    @Environment(\.openURL) private var openURL

    var body: some View {
        let source = section.source
        HStack(spacing: 4) {
            Text("\(source.path.fullPath) on \(source.kind.shortTitle)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let page = source.hosted.url(forChecksOf: commit) {
                Button("Open on \(source.kind.shortTitle)", systemImage: "arrow.up.forward.square") { openURL(page) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Open this commit’s checks on \(source.kind.shortTitle)")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        if let runs = section.entry.runs {
            let groups = runs.grouped
            ForEach(groups) { group in
                // Checks with no workflow or stage are not the last one's.
                if let title = group.title ?? (groups.count > 1 ? "Other" : nil) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                ForEach(group.runs) { run in
                    CheckRunRow(run: run)
                }
            }
        } else if let status = section.entry.status {
            // Until its checks are listed, how they stand overall.
            Text(status.summary)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
        }
    }
}

/// One check: how it went, its name, and how long it took or what became
/// of it. A click opens its page.
private struct CheckRunRow: View {
    var run: CheckRun

    @Environment(\.openURL) private var openURL
    @State private var isHovered = false

    var body: some View {
        Button {
            if let url = run.url { openURL(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: run.status.symbol)
                    .foregroundStyle(run.status.color)
                    .imageScale(.small)
                    .accessibilityLabel(run.status.summary)
                Text(run.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let note {
                    // Whole where it is a word or a time; a service's own
                    // description gives way to the name.
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(maxWidth: 130, alignment: .trailing)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered && run.url != nil ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(run.url.map { "Open \($0.host() ?? "its page")" } ?? "")
    }

    /// What became of it where the mark does not say, else how long it took.
    private var note: String? {
        if let detail = run.detail { return detail }
        guard let duration = run.duration else { return nil }
        return Duration.seconds(duration.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}
