import GitKit
import SwiftUI

/// What wants looking at across every listed repository: everything not yet
/// committed or pushed, which would be lost with this device, and what
/// waits elsewhere, to be pulled or to be reviewed.
struct ReviewView: View {
    var query: String
    var open: (RepositoryBookmark) -> Void

    @Environment(RepositoryLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(WindowActions.self) private var actions
    @State private var model: ReviewModel
    private var captions: ReviewCaptions { .shared }
    private var expansion: ReviewExpansion { .shared }
    private var accountChanges: AccountChangeCounter { .shared }

    /// - Parameter model: What reads the repositories and asks their
    ///   services; a test gives one whose services are recorded answers.
    init(query: String, open: @escaping (RepositoryBookmark) -> Void, model: ReviewModel = ReviewModel()) {
        self.query = query
        self.open = open
        _model = State(initialValue: model)
    }

    var body: some View {
        let listed = model.needingAttention
        let reviews = listed.filter { $0.matches(query) }
        // Read here so the rows fold and open as it changes.
        let _ = expansion.expanded
        List {
            if !listed.isEmpty {
                Section {
                    Label(ReviewTotals(listed).sentence, systemImage: "tray.full")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(reviews) { review in
                    DisclosureGroup(isExpanded: isExpanded(review)) {
                        work(in: review)
                    } label: {
                        ReviewRow(
                            review: review, caption: captions.caption(for: review.id),
                            isPushing: model.pushing.contains(review.id),
                            open: { open(review) }, push: { push(review) }
                        )
                        .contextMenu {
                            Button("Open", systemImage: "arrow.right.circle") { open(review) }
                        }
                        // Only for rows the list shows, and again when the changes change.
                        .task(id: review) { await captions.describe(review, in: library) }
                    }
                }
            }
        }
        .overlay {
            if reviews.isEmpty {
                if model.isLoading, listed.isEmpty {
                    ProgressView("Reading repositories…")
                } else if !query.isEmpty, !listed.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView(
                        "Nothing to Review", systemImage: "checkmark.seal",
                        description: Text(
                            "Everything in every repository is committed, pushed and up to date, and no pull request waits for your review."
                        )
                    )
                }
            }
        }
        .refreshable { await model.load(library.listedBookmarks, from: library, asksAgain: true) }
        .task(id: Key(
            ids: library.listedBookmarks.map(\.id), isActive: scenePhase == .active, accounts: accountChanges.count
        )) {
            guard scenePhase == .active else { return }
            model.accountsChanged(to: accountChanges.count)
            await model.load(library.listedBookmarks, from: library)
        }
        .onChange(of: model.notice) {
            // Said in the window's strip, with everything else.
            guard let notice = model.notice else { return }
            actions.notices.post(notice)
            model.notice = nil
        }
        .onChange(of: library.listedBookmarks.map(\.id), initial: true) { _, ids in
            captions.retain(Set(ids))
        }
    }

    /// Read again when the list changes, the app comes back to the front,
    /// or an account is added or removed.
    private struct Key: Hashable {
        var ids: [UUID]
        var isActive: Bool
        var accounts: Int
    }

    /// What a repository's row folds away: its changed files and the
    /// commits to push, then what waits elsewhere: the commits to pull, on
    /// its branch and on others, and the pull requests to review.
    @ViewBuilder
    private func work(in review: RepositoryReview) -> some View {
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
        if let sentence = review.pullSentence {
            Label(sentence, systemImage: "arrow.down")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(review.otherBranches) { branch in
            Label(branch.pullSentence, systemImage: "arrow.down")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(review.reviewRequests) { request in
            Button { open(review) } label: { ReviewRequestRow(request: request) }
                .buttonStyle(.plain)
                .pointerHover()
                .contextMenu {
                    Button("Open Repository", systemImage: "arrow.right.circle") { open(review) }
                    if let url = request.webURL {
                        Button("Open in Browser", systemImage: "safari") { openURL(url) }
                        Button("Copy Link", systemImage: "link") { Platform.copyToClipboard(url.absoluteString) }
                    }
                }
        }
        if review.hasMoreReviewRequests {
            Text("and more to review on the service")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Folded shut unless opened; always open while searching, so the
    /// matching files and commits show.
    private func isExpanded(_ review: RepositoryReview) -> Binding<Bool> {
        Binding {
            !query.isEmpty || expansion.expanded.contains(review.id)
        } set: { isExpanded in
            if isExpanded {
                expansion.expanded.insert(review.id)
            } else {
                expansion.expanded.remove(review.id)
            }
        }
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

/// Which repositories the Review shows opened, kept for as long as the app
/// runs: the Review is made anew each time it is shown.
@MainActor
@Observable
final class ReviewExpansion {
    static let shared = ReviewExpansion()

    var expanded: Set<UUID> = []
}

/// A repository with what wants looking at folded away beneath it: what
/// that comes to, and what the on-device model says its work is about.
private struct ReviewRow: View {
    var review: RepositoryReview
    var caption: String?
    var isPushing: Bool
    var open: () -> Void
    var push: () -> Void

    var body: some View {
        Label {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button(action: open) {
                            Text(review.name)
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
                    }
                    Text(review.summary)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let caption {
                        Label(caption, systemImage: "sparkles")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help("Written on this device by Apple Intelligence")
                            .transition(.opacity)
                    }
                }
                .animation(.default, value: caption)
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
        } icon: {
            Image(systemName: "folder")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// A pull request that waits for the account's review: its number, its
/// title, and who opened it.
private struct ReviewRequestRow: View {
    var request: ReviewRequest

    var body: some View {
        HStack(spacing: 8) {
            // As wide for either symbol, so the numbers line up.
            Image(systemName: request.isDraft ? "circle.dashed" : "arrow.triangle.pull")
                .foregroundStyle(request.isDraft ? Color.secondary : Color.green)
                .frame(width: 18)
                .accessibilityLabel(request.isDraft ? "Draft \(request.kind.pullRequestTerm)" : request.kind.pullRequestTerm)
            Text(request.reference)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(request.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let author = request.author {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .help("\(request.kind.pullRequestTerm) \(request.reference) asks for your review")
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
