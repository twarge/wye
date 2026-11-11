import SwiftUI

/// The repository's pull requests on its hosting service, filtered, a page
/// at a time. Selecting one shows it in the detail column.
struct PullRequestListView: View {
    var model: RepositoryModel

    private var changes = AccountChangeCounter.shared

    init(model: RepositoryModel) {
        self.model = model
    }

    var body: some View {
        let availability = model.hostingAvailability()
        let list = model.hosting.pullRequests
        Group {
            switch availability {
            case .ready(let target, let account, let service):
                PullRequestRows(model: model, list: list, target: target, service: service)
                    .task(id: PullRequestList.key(target: target, account: account, filter: list.filter)) {
                        await list.load(target: target, account: account, service: service)
                    }
                    .refreshable {
                        await list.load(target: target, account: account, service: service, force: true)
                    }
                    .toolbar { toolbar(target: target, account: account, service: service) }
                    .navigationTitle(target.kind.pullRequestTerm + "s")
            case .noHostedRemote, .noAccount:
                unavailable(availability)
                    .navigationTitle("Pull Requests")
            }
        }
        // Accounts added or removed in Settings take effect here.
        .id(changes.count)
    }

    private func unavailable(_ availability: HostingAvailability) -> some View {
        ContentUnavailableView {
            Label(model.hostingTargets.isEmpty ? "No Hosted Remote" : "No Account", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text(availability.message ?? "")
        } actions: {
            if case .noAccount = availability {
                SettingsButton { Text("Open Settings") }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(target: HostingTarget, account: HostingAccount, service: any HostingService) -> some ToolbarContent {
        @Bindable var list = model.hosting.pullRequests
        ToolbarItem(placement: .primaryAction) {
            Picker("Show", selection: $list.filter) {
                ForEach(PullRequestFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .help("Which \(target.kind.pullRequestTerm.lowercased())s to list")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("New \(target.kind.pullRequestTerm)…", systemImage: "plus") {
                model.hosting.sheet = .newPullRequest(head: model.currentBranch?.id)
            }
            .help("Open a \(target.kind.pullRequestTerm.lowercased()) from a branch")
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu("Remote", systemImage: "cloud") {
                Picker("Remote", selection: Binding {
                    target.remote
                } set: {
                    model.hosting.chosenRemote = $0
                    model.hosting.selectedPullRequest = nil
                }) {
                    ForEach(model.hostingTargets) { target in
                        Text("\(target.remote) (\(target.path.fullPath))").tag(target.remote)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Text("Signed in as \(account.title)")
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await list.load(target: target, account: account, service: service, force: true) }
                }
                .keyboardShortcut("r")
            }
            .help("The remote whose \(target.kind.pullRequestTerm.lowercased())s are listed")
        }
    }
}

private struct PullRequestRows: View {
    var model: RepositoryModel
    var list: PullRequestList
    var target: HostingTarget
    var service: any HostingService

    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var hosting = model.hosting
        List(selection: $hosting.selectedPullRequest) {
            ForEach(list.items) { pullRequest in
                PullRequestRow(pullRequest: pullRequest, kind: target.kind)
                    .tag(pullRequest.number)
                    .contextMenu { menu(for: pullRequest) }
            }
            if list.next != nil {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .task(id: list.items.count) {
                    await list.loadMore(target: target, service: service)
                }
            }
        }
        .overlay {
            if list.items.isEmpty {
                if list.isLoading {
                    ProgressView()
                } else if let failure = list.failure {
                    ContentUnavailableView {
                        Label("Couldn’t Load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure)
                    } actions: {
                        if list.failureNeedsSignIn {
                            SettingsButton { Text("Open Settings") }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No \(list.filter.title) \(target.kind.pullRequestTerm)s", systemImage: "arrow.triangle.pull",
                        description: Text("On \(target.path.fullPath)")
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !list.items.isEmpty, let failure = list.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private func menu(for pullRequest: PullRequest) -> some View {
        Button("Check Out", systemImage: "arrow.uturn.down") {
            Task { await model.checkOutPullRequest(pullRequest, target: target, service: service) }
        }
        .disabled(model.isTransferring || model.isBusy || pullRequest.state == .merged)
        if let url = pullRequest.webURL {
            Button("Open in Browser", systemImage: "safari") { openURL(url) }
            Button("Copy Link", systemImage: "link") { Platform.copyToClipboard(url.absoluteString) }
        }
    }
}

/// One pull request in the list.
struct PullRequestRow: View {
    var pullRequest: PullRequest
    var kind: HostingKind

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PullRequestStateIcon(state: pullRequest.state, isDraft: pullRequest.isDraft)
                Text(pullRequest.title)
                    .lineLimit(2)
                    .fontWeight(.medium)
                Spacer(minLength: 4)
                if let checks = pullRequest.checks {
                    CheckStatusIcon(status: checks)
                }
                if let review = pullRequest.review {
                    ReviewStateIcon(state: review)
                }
            }
            HStack(spacing: 6) {
                Text(kind.reference(pullRequest.number))
                    .monospacedDigit()
                if let author = pullRequest.author {
                    Text(author.login)
                }
                if pullRequest.isDraft {
                    Text("Draft")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .background(.quaternary, in: .capsule)
                }
                Spacer(minLength: 4)
                if let updated = pullRequest.updatedAt {
                    Text(updated, format: .relative(presentation: .named))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("\(pullRequest.head.name) → \(pullRequest.base.name)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct PullRequestStateIcon: View {
    var state: PullRequestState
    var isDraft: Bool

    var body: some View {
        let (symbol, color, label): (String, Color, String) = switch state {
        case .open where isDraft: ("circle.dashed", .secondary, "Draft")
        case .open: ("arrow.triangle.pull", .green, "Open")
        case .merged: ("arrow.triangle.merge", .purple, "Merged")
        case .closed: ("xmark.circle", .red, "Closed")
        }
        Image(systemName: symbol)
            .foregroundStyle(color)
            .help(label)
            .accessibilityLabel(label)
    }
}

struct CheckStatusIcon: View {
    var status: CheckStatus

    var body: some View {
        let (symbol, color, label): (String, Color, String) = switch status {
        case .success: ("checkmark.circle.fill", .green, "Checks passed")
        case .failure: ("xmark.circle.fill", .red, "Checks failed")
        case .pending: ("clock.fill", .orange, "Checks running")
        case .neutral: ("minus.circle", .secondary, "Checks neutral or skipped")
        }
        Image(systemName: symbol)
            .foregroundStyle(color)
            .imageScale(.small)
            .help(label)
            .accessibilityLabel(label)
    }
}

struct ReviewStateIcon: View {
    var state: ReviewState

    var body: some View {
        let (symbol, color, label): (String, Color, String) = switch state {
        case .approved: ("hand.thumbsup.fill", .green, "Approved")
        case .changesRequested: ("exclamationmark.bubble.fill", .orange, "Changes requested")
        case .reviewRequired: ("eye", .secondary, "Review required")
        }
        Image(systemName: symbol)
            .foregroundStyle(color)
            .imageScale(.small)
            .help(label)
            .accessibilityLabel(label)
    }
}
