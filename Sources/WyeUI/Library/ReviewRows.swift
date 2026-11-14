import GitKit
import SwiftUI

/// What wants looking at across every listed repository, at the top of
/// their list: everything not yet committed or pushed, which would be lost
/// with this device, and what waits elsewhere, to be pulled, to be fixed or
/// to be reviewed. Or that there is nothing, once every repository is read.
struct ReviewTotalsRow: View {
    var totals: ReviewTotals

    var body: some View {
        Label(totals.sentence, systemImage: totals.repositories > 0 ? "tray.full" : "checkmark.seal")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// What a repository's row folds away: its changed files and the commits to
/// push, then what waits elsewhere: the commits to pull, on its branch and
/// on others, the branches whose checks failed, and the pull requests to
/// review. Each row opens the repository.
struct ReviewWork: View {
    var review: RepositoryReview
    var open: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ForEach(review.entries) { entry in
            Button(action: open) { ReviewFileRow(entry: entry) }
                .buttonStyle(.plain)
                .pointerHover()
        }
        if review.isUnpublished {
            Label("“\(review.branch ?? "")” is not published to a remote", systemImage: "icloud.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(review.commits) { commit in
            Button(action: open) {
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
        ForEach(review.failedChecks) { check in
            Button(action: open) { FailedCheckRow(check: check) }
                .buttonStyle(.plain)
                .pointerHover()
                .contextMenu {
                    Button("Open Repository", systemImage: "arrow.right.circle", action: open)
                    if let url = check.webURL {
                        Button("Open Checks in Browser", systemImage: "safari") { openURL(url) }
                        Button("Copy Link", systemImage: "link") { Platform.copyToClipboard(url.absoluteString) }
                    }
                    Button("Copy Hash", systemImage: "doc.on.doc") { Platform.copyToClipboard(check.commit.hex) }
                }
        }
        ForEach(review.reviewRequests) { request in
            Button(action: open) { ReviewRequestRow(request: request) }
                .buttonStyle(.plain)
                .pointerHover()
                .contextMenu {
                    Button("Open Repository", systemImage: "arrow.right.circle", action: open)
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
}

/// Which repositories the list shows opened on what they fold away, kept
/// for as long as the app runs: the list is made anew each time it is shown.
@MainActor
@Observable
final class ReviewExpansion {
    static let shared = ReviewExpansion()

    var expanded: Set<UUID> = []
}

/// An active branch whose newest pushed commit failed its checks: the
/// branch, and the commit they ran for.
private struct FailedCheckRow: View {
    var check: FailedCheck

    var body: some View {
        HStack(spacing: 8) {
            // As wide as a pull request's symbol, so the rows line up.
            Image(systemName: CheckStatus.failure.symbol)
                .foregroundStyle(CheckStatus.failure.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(check.sentence)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(check.commit.abbreviated())
                .font(.smallCode)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .help("The newest commit pushed to \(check.upstream) failed its checks")
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
