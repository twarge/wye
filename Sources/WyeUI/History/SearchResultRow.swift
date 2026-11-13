import GitKit
import SwiftUI

/// A commit found by a search. Matches are rarely next to each other in the
/// history, so the row has no graph.
struct SearchResultRow: View {
    var commit: Commit
    var labels: [RefLabel]
    /// The author is on the second line whatever this says.
    var columns = HistoryColumns()
    /// `HEAD`'s commit is bold, in place of a badge.
    var isHead = false
    var hasNote = false
    /// How its checks stand on the hosting services, where any ran.
    var checks: CheckStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ForEach(labels) { label in
                    RefBadge(label: label)
                        .fixedSize()
                }
                Text(commit.summary)
                    .fontWeight(isHead ? .bold : nil)
                    .lineLimit(1)
                if hasNote {
                    NoteMark()
                }
                if let checks {
                    Spacer(minLength: 0)
                    CommitCheckMark(commit: commit.id, status: checks, scale: .medium)
                }
            }
            HStack(spacing: 6) {
                if columns.hash {
                    Text(commit.id.abbreviated())
                        .font(.smallCode)
                }
                Text(commit.author.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if columns.date {
                    Text(commit.author.date, format: .dateTime.day().month(.defaultDigits).year(.twoDigits))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isHead ? "HEAD" : "")
    }
}

/// The mark on a commit that has a note.
struct NoteMark: View {
    var body: some View {
        Image(systemName: "note.text")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .help("This commit has a note")
            .accessibilityLabel("Has a note")
    }
}

/// The end of the results while the search is still going.
struct SearchProgressRow: View {
    var examined: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Searched \(examined.formatted()) commits")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}
