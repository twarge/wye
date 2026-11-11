import GitKit
import SwiftUI

/// Pushes one commit to a chosen branch of a chosen remote. A push that
/// would take commits off the remote branch says so and needs a force push.
struct PushRevisionSheet: View {
    var model: RepositoryModel
    var commit: OID

    @State private var remote: String
    @State private var branch: String
    /// Whether the push only adds commits there, as the last fetch saw it;
    /// `nil` while it is being worked out.
    @State private var isFastForward: Bool?

    init(model: RepositoryModel, commit: OID) {
        self.model = model
        self.commit = commit
        let remote = model.defaultRemoteName ?? model.remoteNames.first ?? ""
        _remote = State(initialValue: remote)
        _branch = State(initialValue: model.headBranchName ?? "")
    }

    var body: some View {
        BranchingSheetForm(
            title: "Push Revision",
            confirmTitle: isFastForward == false ? "Force Push" : "Push",
            isDestructive: isFastForward == false,
            canConfirm: canPush,
            confirm: push
        ) {
            Section {
                LabeledContent("Commit") {
                    Text(commit.abbreviated())
                        .font(.code)
                }
                Picker("Remote", selection: $remote) {
                    ForEach(model.remoteNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                TextField("Remote Branch", text: $branch)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
            } footer: {
                Text(footer)
            }
        }
        .task(id: Key(remote: remote, branch: trimmed)) {
            isFastForward = nil
            guard !remote.isEmpty, !trimmed.isEmpty else { return }
            // Waits for a pause in typing.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            isFastForward = (try? await model.repository.pushWouldFastForward(commit, to: remote, as: trimmed)) ?? true
        }
    }

    private struct Key: Hashable {
        var remote: String
        var branch: String
    }

    private var trimmed: String { branch.trimmingCharacters(in: .whitespaces) }

    private var canPush: Bool {
        !remote.isEmpty && !trimmed.isEmpty && isFastForward != nil && !model.isTransferring
    }

    private var footer: String {
        let destination = "“\(remote)/\(trimmed)”"
        switch isFastForward {
        case false?:
            return "\(destination) has commits that \(commit.abbreviated()) does not. Pushing moves the branch there "
                + "and those commits are lost on the remote unless another branch holds them. "
                + "Wye refuses if \(destination) changed since the last fetch."
        default:
            return "Moves \(destination) to \(commit.abbreviated()), making the branch if the remote has none of "
                + "that name. Nothing here changes."
        }
    }

    private func push() {
        let (commit, remote, branch, force) = (commit, remote, trimmed, isFastForward == false)
        Task { await model.push(commit: commit, to: remote, as: branch, force: force) }
    }
}

/// Confirms force pushing a branch to its upstream, saying what is lost.
struct ForcePushBranchSheet: View {
    var model: RepositoryModel
    /// The local branch, by full reference name.
    var branch: String

    var body: some View {
        BranchingSheetForm(
            title: "Force Push", confirmTitle: "Force Push", isDestructive: true,
            canConfirm: upstream != nil && !model.isTransferring, confirm: push
        ) {
            Section {
                LabeledContent("Branch", value: name)
                LabeledContent("To", value: upstream?.name ?? "No upstream")
            } footer: {
                if let upstream {
                    Text("Commits on \(upstream.name) that are not on “\(name)” will be lost there. "
                         + "Wye refuses if \(upstream.name) changed since the last fetch, so work you have not "
                         + "seen is never overwritten.")
                } else {
                    Text("“\(name)” has no upstream to force push to. Publish it first.")
                }
            }
        }
    }

    private var name: String { RepositoryModel.displayName(ofReference: branch) }

    private var upstream: Branch.Upstream? {
        model.snapshot?.branches.first { $0.id == branch }?.upstream
    }

    private func push() {
        let branch = branch
        Task { await model.forcePush(branch: branch) }
    }
}
