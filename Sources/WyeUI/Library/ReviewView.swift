import GitKit
import SwiftUI

/// Everything not yet committed or pushed, across every listed repository:
/// what would be lost with this device.
struct ReviewView: View {
    var query: String
    var open: (RepositoryBookmark) -> Void

    @Environment(RepositoryLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Environment(WindowActions.self) private var actions
    @State private var model = ReviewModel()

    var body: some View {
        let reviews = model.withWork.filter { $0.matches(query) }
        List {
            if !model.withWork.isEmpty {
                Section {
                    Label(ReviewTotals(model.withWork).sentence, systemImage: "tray.full")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(reviews) { review in
                Section {
                    ForEach(review.entries) { entry in
                        Button { open(review) } label: { ReviewFileRow(entry: entry) }
                            .buttonStyle(.plain)
                            .pointerHover()
                    }
                    if review.isUnpublished {
                        Label("“\(review.branch ?? "")” is not published to a remote", systemImage: "icloud.slash")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(review.commits) { commit in
                        Button { open(review) } label: {
                            SearchResultRow(commit: commit, labels: [])
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .pointerHover()
                    }
                    if review.ahead > review.commits.count {
                        Text("and \(review.ahead - review.commits.count) more unpushed commits")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    ReviewHeader(
                        review: review, isPushing: model.pushing.contains(review.id),
                        open: { open(review) }, push: { push(review) }
                    )
                }
            }
        }
        .overlay {
            if reviews.isEmpty {
                if model.isLoading, model.withWork.isEmpty {
                    ProgressView("Reading repositories…")
                } else if !query.isEmpty, !model.withWork.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView(
                        "Nothing to Review", systemImage: "checkmark.seal",
                        description: Text("Everything in every repository is committed and pushed.")
                    )
                }
            }
        }
        .refreshable { await model.load(library.listedBookmarks, from: library) }
        .task(id: Key(ids: library.listedBookmarks.map(\.id), isActive: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            await model.load(library.listedBookmarks, from: library)
        }
        .onChange(of: model.notice) {
            // Said in the window's strip, with everything else.
            guard let notice = model.notice else { return }
            actions.notices.post(notice)
            model.notice = nil
        }
    }

    /// Read again when the list changes or the app comes back to the front.
    private struct Key: Hashable {
        var ids: [UUID]
        var isActive: Bool
    }

    private func open(_ review: RepositoryReview) {
        guard let bookmark = library.bookmarks.first(where: { $0.id == review.id }) else { return }
        open(bookmark)
    }

    private func push(_ review: RepositoryReview) {
        guard let bookmark = library.bookmarks.first(where: { $0.id == review.id }) else { return }
        Task { await model.push(bookmark, in: library) }
    }
}

private struct ReviewHeader: View {
    var review: RepositoryReview
    var isPushing: Bool
    var open: () -> Void
    var push: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                Label(review.name, systemImage: "folder")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Open this repository")
            if let branch = review.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if review.behind > 0 {
                Label("\(review.behind)", systemImage: "arrow.down")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("^[\(review.behind) commit](inflect: true) to pull")
            }
            if isPushing {
                ProgressView().controlSize(.small)
            } else if review.ahead > 0 || review.isUnpublished {
                Button(action: push) {
                    Label(
                        review.isUnpublished ? "Publish" : "Push \(review.ahead)",
                        systemImage: "arrow.up"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(review.isUnpublished ? "Publish this branch to its remote" : "Push these commits to \(review.upstream ?? "the remote")")
            }
        }
        .textCase(nil)
    }
}

private struct ReviewFileRow: View {
    var entry: StatusEntry

    var body: some View {
        HStack(spacing: 8) {
            FileChangeBadge(change: entry.change)
            Text(entry.path)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(stage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var stage: String {
        switch (entry.staged != nil, entry.unstaged != nil) {
        case (true, true): "Partly staged"
        case (true, false): "Staged"
        default: ""
        }
    }
}
