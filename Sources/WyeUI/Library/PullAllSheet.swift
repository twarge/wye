import SwiftUI

/// Pull All's progress, then its report: what did not work first.
struct PullAllSheet: View {
    var model: PullAllModel
    var open: (RepositoryBookmark) -> Void

    @Environment(RepositoryLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetStack("Pull All", placement: .above(inset: 16)) {
            List {
                Section {
                    ForEach(PullAllReport.sorted(model.results)) { result in
                        PullAllRow(result: result) {
                            guard let bookmark = library.bookmarks.first(where: { $0.id == result.id }) else { return }
                            dismiss()
                            open(bookmark)
                        }
                    }
                } header: {
                    if model.isRunning {
                        ProgressView(value: Double(model.finishedCount), total: Double(max(model.results.count, 1))) {
                            Text("Pulling \(model.finishedCount) of \(model.results.count)")
                        }
                    } else {
                        Text(PullAllReport.summary(of: model.results))
                    }
                }
            }
            .overlay {
                if model.results.isEmpty {
                    ContentUnavailableView(
                        "No Repositories", systemImage: "arrow.down.circle",
                        description: Text("Add a repository to pull it here.")
                    )
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(model.isRunning)
                }
                if model.isRunning {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Stop") { model.cancel() }
                    }
                }
            }
        }
        // A Mac's sheet is as large as its content asks; an iPhone's is
        // the screen's width, which a minimum must not exceed.
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
        .interactiveDismissDisabled(model.isRunning)
    }
}

private struct PullAllRow: View {
    var result: PullAllResult
    var open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if result.isProblem {
                Button("Open", action: open)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch result.outcome {
        case .waiting:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .pulling:
            ProgressView().controlSize(.small)
        case .upToDate:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .updated:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .needsAttention:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var detail: String? {
        switch result.outcome {
        case .waiting: nil
        case .pulling: "Pulling…"
        case .upToDate: "Already up to date."
        case .updated(let text), .skipped(let text), .needsAttention(let text), .failed(let text): text
        }
    }
}
