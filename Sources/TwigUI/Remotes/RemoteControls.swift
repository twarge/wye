import GitKit
import SwiftUI

extension View {
    /// Fetch, Pull and Push in the toolbar, with the running operation's
    /// progress, and the sheets and confirmations they lead to.
    func remoteControls(for model: RepositoryModel) -> some View {
        modifier(RemoteControls(model: model))
    }
}

private struct RemoteControls: ViewModifier {
    @Bindable var model: RepositoryModel

    func body(content: Content) -> some View {
        @Bindable var remotes = model.remotes
        @Bindable var credentials = model.remotes.credentials
        content
            .toolbar {
                ToolbarItemGroup(placement: Platform.remoteToolbarPlacement) {
                    if let activity = remotes.activity {
                        RemoteActivityView(activity: activity) { model.cancelRemoteOperation() }
                    }
                    RemoteButtons(model: model)
                }
            }
            .sheet(item: $credentials.prompt, onDismiss: { credentials.decline() }) { prompt in
                CredentialsSheet(prompt: prompt, broker: credentials)
            }
            .sheet(isPresented: $remotes.isManagingRemotes) {
                RemoteListSheet(model: model)
            }
            .confirmationDialog(
                forcePushTitle, isPresented: $remotes.isConfirmingForcePush, titleVisibility: .visible
            ) {
                Button("Force Push", role: .destructive) {
                    Task { await model.push(force: true) }
                }
            } message: {
                Text(forcePushMessage)
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

    var body: some View {
        let isBusy = model.remotes.activity != nil
        let upstream = model.currentBranch?.upstream
        Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
            Task { await model.fetch() }
        }
        .disabled(isBusy || !model.hasRemotes)
        .help("Fetch from every remote, removing remote branches that were deleted")

        Button("Pull", systemImage: "arrow.down") {
            Task { await model.pull() }
        }
        .badge(upstream?.behind ?? 0)
        .disabled(isBusy || upstream == nil)
        .help(pullHelp(upstream))

        Button("Push", systemImage: "arrow.up") {
            Task { await model.push() }
        }
        .badge(upstream?.ahead ?? 0)
        .disabled(isBusy || model.currentBranch == nil || !model.hasRemotes)
        .help(pushHelp(upstream))

        Menu("More Remote Actions", systemImage: "ellipsis") {
            Button("Force Push…", systemImage: "exclamationmark.arrow.triangle.2.circlepath") {
                model.remotes.isConfirmingForcePush = true
            }
            .disabled(isBusy || upstream == nil)
            Divider()
            Button("Remotes…", systemImage: "server.rack") {
                model.remotes.isManagingRemotes = true
            }
        }
        .help("Force push, and add or change remotes")
    }

    private func pullHelp(_ upstream: Branch.Upstream?) -> String {
        guard let upstream else { return "The current branch has no upstream to pull from" }
        return upstream.behind == 0
            ? "Pull from \(upstream.name)"
            : "Pull \(upstream.behind) \(upstream.behind == 1 ? "commit" : "commits") from \(upstream.name)"
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
