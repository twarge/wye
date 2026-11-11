import GitKit
import SwiftUI

/// The selected pull request: what it is and where it stands, then its
/// conversation, commits and changed files, and what can be done with it.
struct PullRequestDetailView: View {
    var model: RepositoryModel

    var body: some View {
        if let number = model.hosting.selectedPullRequest,
           case .ready(let target, _, let service) = model.hostingAvailability() {
            Group {
                if let detail = model.hosting.detail, detail.number == number {
                    PullRequestDetailContent(model: model, detail: detail, target: target, service: service)
                } else {
                    ProgressView()
                }
            }
            .id("\(target.remote)#\(number)")
            .task(id: "\(target.remote)#\(number)") {
                // Made here rather than while drawing, which must not change state.
                model.hosting.showDetail(for: number)
            }
        } else {
            ContentUnavailableView("No \(model.pullRequestTarget?.kind.pullRequestTerm ?? "Pull Request") Selected", systemImage: "arrow.triangle.pull")
        }
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case conversation = "Conversation"
    case commits = "Commits"
    case files = "Files"

    var id: Self { self }
}

private struct PullRequestDetailContent: View {
    var model: RepositoryModel
    var detail: PullRequestDetail
    var target: HostingTarget
    var service: any HostingService

    @Environment(\.openURL) private var openURL
    @State private var tab = DetailTab.conversation
    @State private var draft = ""
    @State private var merging: MergeMethod?
    @State private var isConfirmingClose = false
    @State private var collapsed: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let pullRequest = detail.pullRequest {
                    header(pullRequest)
                    if let failure = detail.actionFailure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    ForEach(detail.partialFailures, id: \.self) { failure in
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !pullRequest.body.isEmpty {
                        MarkdownView(text: pullRequest.body)
                            .padding(12)
                            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                    }
                    Picker("Show", selection: $tab) {
                        ForEach(DetailTab.allCases) { tab in
                            Text(title(of: tab)).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch tab {
                    case .conversation: conversation(pullRequest)
                    case .commits: commits
                    case .files: files(pullRequest)
                    }
                } else if let failure = detail.failure {
                    ContentUnavailableView("Couldn’t Load", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .task {
            if detail.pullRequest == nil { await reload() }
        }
        .refreshable { await reload() }
        .confirmationDialog(
            mergeTitle, isPresented: Binding { merging != nil } set: { if !$0 { merging = nil } },
            titleVisibility: .visible, presenting: merging
        ) { method in
            Button(method.title) { merge(method) }
        } message: { method in
            Text(mergeMessage(method))
        }
        .confirmationDialog(
            "Close \(target.kind.reference(detail.number))?", isPresented: $isConfirmingClose, titleVisibility: .visible
        ) {
            Button(target.kind == .bitbucket ? "Decline" : "Close", role: .destructive) { setOpen(false) }
        } message: {
            Text(service.capabilities.canReopen
                 ? "It can be reopened later. Its branch stays."
                 : "Bitbucket cannot reopen a declined pull request. Its branch stays.")
        }
    }

    private func title(of tab: DetailTab) -> String {
        switch tab {
        case .conversation: "Conversation" + (detail.conversation.isEmpty ? "" : " (\(detail.conversation.count))")
        case .commits: "Commits" + (detail.commits.isEmpty ? "" : " (\(detail.commits.count))")
        case .files:
            "Files" + ((detail.localComparison?.files.count ?? detail.files.count).nonZero.map { " (\($0))" } ?? "")
        }
    }

    private func reload() async {
        await detail.load(target: target, service: service, repository: model.repository)
        if let pullRequest = detail.pullRequest {
            model.hosting.pullRequests.replace(pullRequest)
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ pullRequest: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                PullRequestStateIcon(state: pullRequest.state, isDraft: pullRequest.isDraft)
                Text(pullRequest.title)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                Text(target.kind.reference(pullRequest.number))
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let author = pullRequest.author {
                    AccountAvatar(url: author.avatarURL, name: author.login, size: 18)
                    Text(author.login).fontWeight(.medium)
                }
                Text("wants to merge")
                    .foregroundStyle(.secondary)
                branchLabel(pullRequest.head, other: pullRequest.isFromOtherRepository)
                Text("into").foregroundStyle(.secondary)
                branchLabel(pullRequest.base, other: false)
            }
            .font(.callout)
            .lineLimit(1)
            HStack(spacing: 12) {
                if pullRequest.isDraft { Label("Draft", systemImage: "circle.dashed") }
                if let checks = pullRequest.checks {
                    Label { Text(checksText(checks)) } icon: { CheckStatusIcon(status: checks) }
                }
                if let review = pullRequest.review {
                    Label { Text(reviewText(review)) } icon: { ReviewStateIcon(state: review) }
                }
                if pullRequest.state == .open, let mergeable = pullRequest.isMergeable {
                    Label(mergeable ? "No conflicts" : "Has conflicts",
                          systemImage: mergeable ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(mergeable ? Color.secondary : Color.orange)
                }
                if let updated = pullRequest.updatedAt {
                    Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            actions(pullRequest)
        }
    }

    private func branchLabel(_ branch: PullRequestBranch, other: Bool) -> some View {
        let owner = other ? branch.repository?.path.map { "\($0.owner):" } ?? "" : ""
        return Text(owner + branch.name)
            .font(.callout.monospaced())
            .padding(.horizontal, 5)
            .background(.quaternary, in: .rect(cornerRadius: 4))
            .truncationMode(.middle)
    }

    @ViewBuilder
    private func actions(_ pullRequest: PullRequest) -> some View {
        let capabilities = service.capabilities
        let busy = detail.isActing
        HStack {
            Button("Check Out", systemImage: "arrow.uturn.down") {
                Task { await model.checkOutPullRequest(pullRequest, target: target, service: service) }
            }
            .disabled(model.isTransferring || model.isBusy)
            .help("Fetch its head into a local branch that tracks it, and check that out")
            if pullRequest.state == .open {
                Menu("Merge", systemImage: "arrow.triangle.merge") {
                    ForEach(capabilities.mergeMethods) { method in
                        Button(method.title) { merging = method }
                    }
                }
                .disabled(busy || pullRequest.isDraft)
                .help(pullRequest.isDraft ? "A draft cannot be merged until it is marked ready" : "Merge it on \(target.kind.title)")
                Button(target.kind == .bitbucket ? "Decline…" : "Close…", systemImage: "xmark.circle") {
                    isConfirmingClose = true
                }
                .disabled(busy)
            } else if pullRequest.state == .closed, capabilities.canReopen {
                Button("Reopen", systemImage: "arrow.uturn.backward.circle") { setOpen(true) }
                    .disabled(busy)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            }
            if let url = pullRequest.webURL {
                Button("Open in Browser", systemImage: "safari") { openURL(url) }
                    .labelStyle(.iconOnly)
                    .help("Open it on \(target.kind.title)")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func checksText(_ status: CheckStatus) -> String {
        switch status {
        case .success: "Checks passed"
        case .failure: "Checks failed"
        case .pending: "Checks running"
        case .neutral: "Checks neutral"
        }
    }

    private func reviewText(_ state: ReviewState) -> String {
        switch state {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        }
    }

    // MARK: Conversation

    @ViewBuilder
    private func conversation(_ pullRequest: PullRequest) -> some View {
        if detail.conversation.isEmpty, !detail.isLoading {
            Text("No comments yet").foregroundStyle(.secondary)
        }
        ForEach(detail.conversation) { comment in
            CommentView(comment: comment)
        }
        composer(pullRequest)
    }

    @ViewBuilder
    private func composer(_ pullRequest: PullRequest) -> some View {
        let capabilities = service.capabilities
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                .accessibilityLabel("Comment")
            HStack {
                Text("Markdown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if pullRequest.state == .open {
                    if capabilities.canRequestChanges {
                        Button("Request Changes") { review(.requestChanges) }
                            .disabled(text.isEmpty || detail.isActing)
                            .help("Say what needs changing in the comment first")
                    }
                    if capabilities.canApprove {
                        Button("Approve") { review(.approve) }
                            .disabled(detail.isActing)
                    }
                }
                Button("Comment") { comment() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty || detail.isActing)
            }
            .controlSize(.small)
        }
    }

    // MARK: Commits and files

    @ViewBuilder
    private var commits: some View {
        let local = detail.localComparison?.onlyRight
        if let local {
            ForEach(local) { commit in
                Button {
                    model.showInHistory(commit.id)
                } label: {
                    SearchResultRow(commit: commit, labels: model.refLabels[commit.id] ?? [])
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show this commit in the history")
            }
        } else {
            if detail.commits.isEmpty, !detail.isLoading {
                Text("No commits").foregroundStyle(.secondary)
            }
            ForEach(detail.commits) { commit in
                HStack(alignment: .firstTextBaseline) {
                    Text(String(commit.sha.prefix(7)))
                        .font(.code)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(commit.subject).lineLimit(2)
                        Text([commit.authorName, commit.date?.formatted(date: .abbreviated, time: .shortened)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func files(_ pullRequest: PullRequest) -> some View {
        if let comparison = detail.localComparison {
            Text("From the fetched commits, against where the branch left \(pullRequest.base.name).")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(comparison.files) { file in
                    FileDiffView(file: file, isCollapsed: isCollapsed(file.id, total: comparison.files.count))
                }
            }
        } else {
            HStack {
                Text("As \(target.kind.title) lists them. Fetch the commits to see the changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fetch Commits", systemImage: "arrow.down.circle") {
                    Task {
                        await model.fetchPullRequestCommits(pullRequest, target: target, service: service)
                        await reload()
                    }
                }
                .controlSize(.small)
                .disabled(model.isTransferring)
            }
            ForEach(detail.files) { file in
                HStack {
                    Image(systemName: symbol(for: file.status))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(file.path).font(.code)
                        if let previous = file.previousPath {
                            Text("from \(previous)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let additions = file.additions, let deletions = file.deletions {
                        Text("+\(additions)").foregroundStyle(.green)
                        Text("−\(deletions)").foregroundStyle(.red)
                    }
                }
                .font(.callout.monospacedDigit())
            }
        }
    }

    private func symbol(for status: PullRequestFile.Status) -> String {
        switch status {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .renamed: "arrow.right.square"
        case .modified: "pencil"
        case .other: "square"
        }
    }

    private func isCollapsed(_ id: String, total: Int) -> Binding<Bool> {
        Binding {
            // Long diffs start folded; the set holds the exceptions.
            collapsed.contains(id) != (total > 10)
        } set: { isCollapsed in
            if isCollapsed != (total > 10) { collapsed.insert(id) } else { collapsed.remove(id) }
        }
    }

    // MARK: Actions

    private var mergeTitle: String {
        "Merge \(target.kind.reference(detail.number)) into \(detail.pullRequest?.base.name ?? "its base")?"
    }

    private func mergeMessage(_ method: MergeMethod) -> String {
        let how = switch method {
        case .merge: "Its commits join the base branch with a merge commit."
        case .squash: "Its commits become one commit on the base branch."
        case .rebase: "Its commits are replayed onto the base branch, without a merge commit."
        }
        return how + " \(target.kind.title) refuses if the head moved since this was loaded."
    }

    private func merge(_ method: MergeMethod) {
        let path = target.path, number = detail.number, head = detail.pullRequest?.head.sha, service = service
        perform { try await service.merge(in: path, number: number, method: method, expectedHead: head) }
    }

    private func setOpen(_ isOpen: Bool) {
        let path = target.path, number = detail.number, service = service
        perform { try await service.setOpen(isOpen, in: path, number: number) }
    }

    private func review(_ verdict: ReviewVerdict) {
        let path = target.path, number = detail.number, service = service
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(clearsDraft: true) { try await service.review(verdict, body: body, in: path, number: number) }
    }

    private func comment() {
        let path = target.path, number = detail.number, service = service
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(clearsDraft: true) { try await service.addComment(body, in: path, number: number) }
    }

    private func perform(clearsDraft: Bool = false, _ action: @escaping @Sendable () async throws -> Void) {
        Task {
            let succeeded = await detail.act(target: target, service: service, repository: model.repository, action)
            if succeeded {
                if clearsDraft { draft = "" }
                if let pullRequest = detail.pullRequest {
                    model.hosting.pullRequests.replace(pullRequest)
                }
            }
        }
    }
}

/// A comment or review in the conversation.
private struct CommentView: View {
    var comment: PullRequestComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AccountAvatar(url: comment.author?.avatarURL, name: comment.author?.login ?? "?", size: 20)
                Text(comment.author?.login ?? "Someone").fontWeight(.semibold)
                kindLabel
                Spacer()
                if let date = comment.createdAt {
                    Text(date, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if !comment.body.isEmpty {
                MarkdownView(text: comment.body)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var kindLabel: some View {
        switch comment.kind {
        case .comment:
            EmptyView()
        case .review(let verdict):
            switch verdict {
            case .approve: Label("approved", systemImage: "hand.thumbsup.fill").foregroundStyle(.green)
            case .requestChanges: Label("requested changes", systemImage: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            case .comment, nil: Text("reviewed").foregroundStyle(.secondary)
            }
        case .lineComment(let path, let line):
            Text("on \(path)\(line.map { ":\($0)" } ?? "")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
