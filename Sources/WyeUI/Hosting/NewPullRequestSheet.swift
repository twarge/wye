import GitKit
import SwiftUI

/// Opens a pull request (a merge request on GitLab) from a pushed branch:
/// base and head, a title and description written from its commits, and
/// whether it is a draft. "Open in Browser" makes it on the service's page
/// instead.
struct NewPullRequestSheet: View {
    var model: RepositoryModel
    /// The local branch to start from, by full reference name.
    var head: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var targetRemote = ""
    @State private var headBranch = ""
    @State private var base = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var isDraft = false
    @State private var hasEditedText = false
    @State private var isCreating = false
    @State private var failure: String?

    var body: some View {
        let target = model.hostingTargets.first { $0.remote == targetRemote }
        let availability = model.hostingAvailability(for: target)
        let source = PullRequestSource.of(headBranch, in: model)
        NavigationStack {
            Form {
                Section {
                    if model.hostingTargets.count > 1 {
                        Picker("Into", selection: $targetRemote) {
                            ForEach(model.hostingTargets) { target in
                                Text("\(target.path.fullPath) (\(target.remote))").tag(target.remote)
                            }
                        }
                    }
                    Picker("Base", selection: $base) {
                        ForEach(baseBranches(target), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Head", selection: $headBranch) {
                        ForEach(model.snapshot?.branches ?? []) { branch in
                            Text(branch.name).tag(branch.id)
                        }
                    }
                } footer: {
                    if let reason = source.problem {
                        Text(reason).foregroundStyle(.orange)
                    } else if let source = source.branch {
                        Text("From \(source.remote)/\(source.name)" + (source.isAhead ? ". Push the branch first: it has commits the remote lacks." : "."))
                    }
                }
                Section {
                    TextField("Title", text: Binding { title } set: { title = $0; hasEditedText = true })
                    TextEditor(text: Binding { bodyText } set: { bodyText = $0; hasEditedText = true })
                        .frame(minHeight: 120)
                        .font(.body)
                        .accessibilityLabel("Description")
                    if case .ready(_, _, let service) = availability, service.capabilities.supportsDrafts {
                        Toggle("Draft", isOn: $isDraft)
                    }
                } footer: {
                    Text("The description is Markdown. Wye wrote these from the branch’s commits.")
                }
                if let message = availability.message {
                    Section { Label(message, systemImage: "person.crop.circle.badge.questionmark") }
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
            .navigationTitle("New \(target?.kind.pullRequestTerm ?? "Pull Request")")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Open in Browser", systemImage: "safari") {
                        if let url = browserURL(target: target, source: source.branch) { openURL(url) }
                        dismiss()
                    }
                    .disabled(browserURL(target: target, source: source.branch) == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create") { create(availability, source: source.branch) }
                            .disabled(!canCreate(availability, source: source))
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear(perform: start)
        .task(id: "\(headBranch)|\(base)|\(targetRemote)") { await prefill() }
    }

    // MARK: Choices

    private func start() {
        targetRemote = model.pullRequestTarget?.remote ?? model.hostingTargets.first?.remote ?? ""
        headBranch = head ?? model.currentBranch?.id ?? model.snapshot?.branches.first?.id ?? ""
        base = defaultBase(model.hostingTargets.first { $0.remote == targetRemote })
    }

    /// The target remote's branches, by name on the remote.
    private func baseBranches(_ target: HostingTarget?) -> [String] {
        guard let target, let remote = model.snapshot?.remotes.first(where: { $0.name == target.remote }) else { return [] }
        let names = remote.branches.map(\.nameWithoutRemote).filter { $0 != "HEAD" }
        return names.contains(base) || base.isEmpty ? names : [base] + names
    }

    private func defaultBase(_ target: HostingTarget?) -> String {
        let names = baseBranches(target)
        if let review = model.interface.review?.base {
            let short = review.hasPrefix("refs/remotes/") ? String(review.split(separator: "/").dropFirst(3).joined(separator: "/"))
                : RepositoryModel.displayName(ofReference: review)
            if names.contains(short) { return short }
        }
        return ["main", "master", "develop", "trunk"].first(where: names.contains) ?? names.first ?? "main"
    }

    private func canCreate(_ availability: HostingAvailability, source: PullRequestSource) -> Bool {
        guard case .ready = availability, let branch = source.branch else { return false }
        let mergesIntoItself = branch.remote == targetRemote && branch.name == base
        return !title.trimmingCharacters(in: .whitespaces).isEmpty && !base.isEmpty && !mergesIntoItself
    }

    private func browserURL(target: HostingTarget?, source: PullRequestSource.Branch?) -> URL? {
        guard let target, let source else { return nil }
        // A head on another remote is opened from that remote's page.
        let hosted = model.hostedRepository(remote: source.remote) ?? target.hosted
        return hosted.newPullRequestURL(forBranch: source.name, into: source.remote == target.remote ? base : nil)
    }

    /// The title and description from the branch's commits: one commit's
    /// own message, or a list of several.
    private func prefill() async {
        guard !hasEditedText, let headID = model.target(of: headBranch),
              let target = model.hostingTargets.first(where: { $0.remote == targetRemote }),
              let baseID = model.target(of: "refs/remotes/\(target.remote)/\(base)") else { return }
        guard let comparison = try? await model.repository.compare(baseID, headID, limit: 50) else { return }
        let draft = PullRequestText.draft(
            commits: comparison.onlyRight.map { [$0.summary, $0.body].filter { !$0.isEmpty }.joined(separator: "\n\n") },
            branch: RepositoryModel.displayName(ofReference: headBranch)
        )
        guard !hasEditedText else { return }
        title = draft.title
        bodyText = draft.body
    }

    private func create(_ availability: HostingAvailability, source: PullRequestSource.Branch?) {
        guard case .ready(let target, _, let service) = availability, let source else { return }
        let headOwner: String? = source.remote == target.remote ? nil
            : model.hostingTargets.first { $0.remote == source.remote }?.path.owner
        let draft = NewPullRequestDraft(
            base: base, head: source.name, headOwner: headOwner,
            title: title.trimmingCharacters(in: .whitespaces), body: bodyText, isDraft: isDraft
        )
        isCreating = true
        failure = nil
        Task {
            defer { isCreating = false }
            do {
                let created = try await service.createPullRequest(draft, in: target.path)
                model.hosting.chosenRemote = target.remote
                model.hosting.pullRequests.invalidate()
                model.hosting.selectedPullRequest = created.number
                model.selection = .pullRequests
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// The remote branch a local branch would open a pull request from.
struct PullRequestSource {
    struct Branch {
        var remote: String
        /// The branch's name on the remote.
        var name: String
        var isAhead: Bool
    }

    var branch: Branch?
    var problem: String?

    @MainActor
    static func of(_ localBranch: String, in model: RepositoryModel) -> PullRequestSource {
        guard let branch = model.snapshot?.branches.first(where: { $0.id == localBranch }) else {
            return PullRequestSource(problem: "Choose a branch.")
        }
        guard let upstream = branch.upstream else {
            return PullRequestSource(problem: "Publish “\(branch.name)” first: a pull request is made from a branch on the remote.")
        }
        guard let remote = model.remoteNames.filter({ upstream.name.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else {
            return PullRequestSource(problem: "“\(branch.name)” tracks a branch on no remote Wye knows.")
        }
        return PullRequestSource(branch: Branch(
            remote: remote, name: String(upstream.name.dropFirst(remote.count + 1)), isAhead: upstream.ahead > 0
        ))
    }
}

/// A pull request's title and description written from its commits.
enum PullRequestText {
    /// Messages newest first, as the history lists them.
    static func draft(commits messages: [String], branch: String) -> (title: String, body: String) {
        let messages = messages.reversed().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if messages.count == 1, let message = messages.first {
            let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        }
        let name = branch.split(separator: "/").last.map(String.init) ?? branch
        let title = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        let words = title.prefix(1).uppercased() + title.dropFirst()
        let body = messages.map { "- " + ($0.split(separator: "\n").first.map(String.init) ?? "") }.joined(separator: "\n")
        return (words, body)
    }
}
