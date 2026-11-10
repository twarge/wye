import GitKit
import SwiftUI

extension View {
    /// Fetch, Pull and Push in the toolbar, with the running operation's
    /// progress.
    func remoteControls(for model: RepositoryModel) -> some View {
        modifier(RemoteControls(model: model))
    }

    /// The sheets, questions and notices of remote operations and of
    /// autostashing. On the whole window, so that they show whichever column
    /// asked for them, also when only the sidebar is on screen.
    func remoteDialogs(for model: RepositoryModel) -> some View {
        modifier(RemoteDialogs(model: model))
    }
}

private struct RemoteControls: ViewModifier {
    @Bindable var model: RepositoryModel

    func body(content: Content) -> some View {
        content
            .remoteBar {
                if let activity = model.remotes.activity {
                    RemoteActivityView(activity: activity) { model.cancelRemoteOperation() }
                }
                RemoteButtons(model: model)
            }
    }
}

private struct RemoteDialogs: ViewModifier {
    @Bindable var model: RepositoryModel

    func body(content: Content) -> some View {
        @Bindable var remotes = model.remotes
        @Bindable var credentials = model.remotes.credentials
        let autostash = model.remotes.autostash
        content
            .sheet(item: $credentials.prompt, onDismiss: { credentials.decline() }) { prompt in
                CredentialsSheet(prompt: prompt, broker: credentials)
            }
            .sheet(isPresented: $remotes.isManagingRemotes) {
                RemoteListSheet(model: model)
            }
            .remoteSheets(model)
            .confirmationDialog(
                forcePushTitle, isPresented: $remotes.isConfirmingForcePush, titleVisibility: .visible
            ) {
                Button("Force Push", role: .destructive) {
                    Task { await model.push(force: true) }
                }
            } message: {
                Text(forcePushMessage)
            }
            .confirmationDialog(
                "Stash Your Local Changes?",
                isPresented: Binding { autostash.pendingAction != nil } set: { if !$0 { autostash.answer(false) } },
                titleVisibility: .visible
            ) {
                Button("Stash and \(autostash.pendingAction ?? "Continue")") { autostash.answer(true) }
                Button("Cancel", role: .cancel) { autostash.answer(false) }
            } message: {
                Text("Local changes are in the way. Twig can set them aside in a stash, "
                     + "\(autostash.pendingAction?.lowercased() ?? "go ahead"), and put them back afterwards.")
            }
            .alert(
                remotes.notice?.title ?? "",
                isPresented: Binding { remotes.notice != nil } set: { if !$0 { remotes.notice = nil } },
                presenting: remotes.notice
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
    }

    private var forcePushTitle: String {
        "Force push “\(model.currentBranch?.name ?? "this branch")”?"
    }

    private var forcePushMessage: String {
        let upstream = model.currentBranch?.upstream?.name ?? "the remote branch"
        return "Commits on \(upstream) that are not on this branch will be lost. "
            + "Twig refuses if \(upstream) changed since the last fetch."
    }
}

private struct RemoteButtons: View {
    var model: RepositoryModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        let isBusy = model.isTransferring
        let upstream = model.currentBranch?.upstream
        Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
            if Platform.isOptionClick {
                model.remotes.sheet = .fetchOptions
            } else {
                Task { await model.fetch() }
            }
        }
        .disabled(isBusy || !model.hasRemotes)
        .contextMenu { fetchMenu }
        .help("Fetch from every remote, removing remote branches that were deleted. Option-click for options.")

        Button("Pull", systemImage: "arrow.down") {
            if Platform.isOptionClick {
                model.remotes.sheet = .pullOptions
            } else {
                Task { await model.pull() }
            }
        }
        .remoteCount(upstream?.behind ?? 0)
        .disabled(isBusy || upstream == nil)
        .contextMenu { pullMenu(upstream) }
        .help(pullHelp(upstream))

        Button("Push", systemImage: "arrow.up") {
            Task { await model.push() }
        }
        .remoteCount(upstream?.ahead ?? 0)
        .disabled(isBusy || model.currentBranch == nil || !model.hasRemotes)
        .contextMenu { pushMenu(upstream) }
        .help(pushHelp(upstream))

        Menu("More Remote Actions", systemImage: "ellipsis") {
            Section {
                Button("Fetch…", systemImage: "arrow.triangle.2.circlepath") { model.remotes.sheet = .fetchOptions }
                    .disabled(isBusy || !model.hasRemotes)
                Button("Pull…", systemImage: "arrow.down") { model.remotes.sheet = .pullOptions }
                    .disabled(isBusy || model.headBranchName == nil || !model.hasRemotes)
                Button("Sync", systemImage: "arrow.up.arrow.down") { Task { await model.sync() } }
                    .disabled(isBusy || upstream == nil)
                    .help("Pull, then push")
                Button("Push to…", systemImage: "arrow.up.to.line") {
                    model.remotes.sheet = .pushTo(branch: model.snapshot?.head.branchName)
                }
                .disabled(isBusy || !model.hasRemotes || model.snapshot?.branches.isEmpty != false)
                Button("Force Push…", systemImage: "exclamationmark.arrow.triangle.2.circlepath") {
                    model.remotes.isConfirmingForcePush = true
                }
                .disabled(isBusy || upstream == nil)
            }
            Section {
                if let remote = model.defaultRemoteName {
                    Button("Push All Tags to “\(remote)”", systemImage: "tag") {
                        Task { await model.pushAllTags(to: remote) }
                    }
                    .disabled(isBusy || model.snapshot?.tags.isEmpty != false)
                    if let url = model.webURL(forRemote: remote) {
                        Button("Open “\(remote)” on Web", systemImage: "safari") { openURL(url) }
                    }
                }
                Button("Remotes…", systemImage: "server.rack") {
                    model.remotes.isManagingRemotes = true
                }
            }
        }
        .help("Pull and fetch with options, sync, push elsewhere, force push, tags and remotes")
    }

    @ViewBuilder
    private var fetchMenu: some View {
        Button("Fetch…", systemImage: "slider.horizontal.3") { model.remotes.sheet = .fetchOptions }
        ForEach(model.remoteNames, id: \.self) { remote in
            Button("Fetch “\(remote)”") {
                Task { await model.fetch(remote: remote, prune: true, tags: .automatic) }
            }
        }
    }

    @ViewBuilder
    private func pullMenu(_ upstream: Branch.Upstream?) -> some View {
        Button("Pull…", systemImage: "slider.horizontal.3") { model.remotes.sheet = .pullOptions }
        ForEach(PullMode.allCases, id: \.self) { mode in
            Button("Pull by \(mode.title)") { Task { await model.pull(mode: mode) } }
                .disabled(upstream == nil)
        }
        Button("Sync", systemImage: "arrow.up.arrow.down") { Task { await model.sync() } }
            .disabled(upstream == nil)
    }

    @ViewBuilder
    private func pushMenu(_ upstream: Branch.Upstream?) -> some View {
        Button("Push to…", systemImage: "arrow.up.to.line") {
            model.remotes.sheet = .pushTo(branch: model.snapshot?.head.branchName)
        }
        Button("Force Push…", systemImage: "exclamationmark.arrow.triangle.2.circlepath") {
            model.remotes.isConfirmingForcePush = true
        }
        .disabled(upstream == nil)
    }

    private func pullHelp(_ upstream: Branch.Upstream?) -> String {
        guard let upstream else { return "The current branch has no upstream to pull from" }
        let what = upstream.behind == 0
            ? "Pull from \(upstream.name)"
            : "Pull \(upstream.behind) \(upstream.behind == 1 ? "commit" : "commits") from \(upstream.name)"
        return what + ". Option-click to choose how."
    }

    private func pushHelp(_ upstream: Branch.Upstream?) -> String {
        guard let upstream else { return "Publish the current branch and make it track the remote branch" }
        return upstream.ahead == 0
            ? "Push to \(upstream.name)"
            : "Push \(upstream.ahead) \(upstream.ahead == 1 ? "commit" : "commits") to \(upstream.name)"
    }
}

/// The running network operation: what it is, how far it has got, and a
/// button to stop it.
struct RemoteActivityView: View {
    var activity: RemoteOperations.Activity
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let fraction = activity.progress?.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(activity.title)
                    .font(.caption.weight(.medium))
                if let progress = activity.progress {
                    Text(progress.summary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Stop \(activity.title.lowercased())")
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

extension TransferProgress {
    /// "Receiving objects 120 of 300", for the activity indicator.
    var summary: String {
        let name = switch phase {
        case .connecting: "Connecting"
        case .receivingObjects: "Receiving objects"
        case .resolvingDeltas: "Resolving deltas"
        case .countingObjects: "Counting objects"
        case .sendingObjects: "Sending objects"
        case .checkingOut: "Checking out files"
        }
        guard total > 0 else { return name }
        var text = "\(name) \(completed.formatted()) of \(total.formatted())"
        if bytes > 0 {
            text += ", " + bytes.formatted(.byteCount(style: .file))
        }
        return text
    }
}
