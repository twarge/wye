import GitKit
import SwiftUI

/// Moves the current branch's commits after one revision onto another, as
/// `git rebase --onto <new base> <upstream>` does: the commits the branch has
/// beyond the upstream are replayed on the new base.
struct RebaseOntoSheet: View {
    var model: RepositoryModel
    @State var newBase: String
    @State private var upstream = ""
    @State private var moved: Int?
    @State private var failure: String?

    var body: some View {
        BranchingSheetForm(title: "Rebase Onto", confirmTitle: "Rebase", canConfirm: canConfirm, confirm: rebase) {
            Section {
                LabeledContent("Branch", value: model.headBranchName ?? "Detached HEAD")
                RevisionField(title: "Commits after", prompt: "Upstream: branch, tag or commit",
                              text: $upstream, choices: choices)
                RevisionField(title: "Onto", prompt: "New base: branch, tag or commit", text: $newBase, choices: choices)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    Text(explanation)
                }
            }
        }
        .task(id: [upstream, newBase]) { await check() }
        .onAppear {
            if upstream.isEmpty, let tracked = model.currentBranch?.upstream?.name {
                upstream = tracked
            }
        }
    }

    private var choices: [RevisionChoice] {
        RevisionChoice.choices(in: model.snapshot).filter { $0.kind != .head }
    }

    private var canConfirm: Bool {
        failure == nil && moved != nil && model.headBranchName != nil && model.canStartMerge
    }

    private var explanation: String {
        let base = newBase.isEmpty ? "the new base" : "“\(shortName(newBase))”"
        let commits = moved.map { "its \($0) \($0 == 1 ? "commit" : "commits")" } ?? "its commits"
        let after = upstream.isEmpty ? "the upstream" : "“\(shortName(upstream))”"
        return "Replays \(commits) that \(after) does not have on top of \(base), making new commits in place of "
            + "the old ones. If the branch was already pushed, publishing it again needs a force push."
    }

    private func shortName(_ revision: String) -> String {
        RepositoryModel.displayName(ofReference: revision)
    }

    /// Resolves both revisions and counts the commits that would move.
    private func check() async {
        moved = nil
        failure = nil
        guard !upstream.isEmpty, !newBase.isEmpty else { return }
        let repository = model.repository
        do {
            let upstreamID = try await repository.resolveRevision(revision(upstream))
            _ = try await repository.resolveRevision(revision(newBase))
            moved = try await repository.headCommitCount(notIn: upstreamID)
        } catch {
            failure = "Choose a branch, tag or commit that is in this repository for both."
        }
    }

    /// A short branch name the field shows becomes its full name.
    private func revision(_ text: String) -> String {
        choices.first { $0.title == text }?.revision ?? text
    }

    private func rebase() {
        let newBase = revision(newBase)
        let upstream = revision(upstream)
        Task { await model.rebaseCurrent(onto: newBase, upstream: upstream) }
    }
}

/// A revision typed in, or chosen from the branches, remote branches and
/// tags, as the revision picker offers them.
struct RevisionField: View {
    var title: String
    var prompt: String
    @Binding var text: String
    var choices: [RevisionChoice]

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $text, prompt: Text(prompt))
                    .labelsHidden()
                    .font(.code)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                Menu {
                    ForEach(choices) { choice in
                        Button(choice.title, systemImage: choice.systemImage) { text = choice.title }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose a branch or tag")
            }
        }
    }
}
