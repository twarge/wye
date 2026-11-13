import GitKit
import SwiftUI

extension View {
    /// Shows the rebasing sheets the menus ask for.
    func rebasePresenters(_ model: RepositoryModel) -> some View {
        modifier(RebasePresenters(model: model, requests: model.rebasing))
    }
}

private struct RebasePresenters: ViewModifier {
    var model: RepositoryModel
    @Bindable var requests: RebaseRequests

    func body(content: Content) -> some View {
        content
            .sheet(item: $requests.interactive) { plan in
                InteractiveRebaseSheet(model: model, plan: plan)
            }
            .sheet(item: $requests.onto) { request in
                RebaseOntoSheet(model: model, newBase: request.newBase)
            }
            .sheet(item: $requests.edit) { request in
                EditCommitSheet(model: model, request: request)
            }
    }
}

/// The commit menu's rebasing items: rebase from it, aim staged changes at
/// it, or edit its message or author.
struct RebaseCommitItems: View {
    var model: RepositoryModel
    var commit: Commit

    var body: some View {
        let requests = model.rebasing
        let isHead = model.snapshot?.head.target == commit.id
        let canRewrite = model.canStartMerge
        Section {
            Button("Rebase Interactively from Here…", systemImage: "list.number") {
                requests.interactive = .from(commit.id)
            }
            .disabled(!canRewrite || commit.isMerge)
            .help("Reorder, reword, squash, fix up or drop this commit and the ones after it")
            Button("Fixup into This Commit", systemImage: "arrow.up.to.line") {
                Task { await model.commitFixup(.fixup, for: commit.id) }
            }
            .disabled(!model.workingCopy.hasStagedChanges || !canRewrite)
            .help("Commit the staged changes as “fixup! \(commit.summary)”, for an autosquash rebase to meld in")
            Button("Squash into This Commit", systemImage: "arrow.up.and.line.horizontal.and.arrow.down") {
                Task { await model.commitFixup(.squash, for: commit.id) }
            }
            .disabled(!model.workingCopy.hasStagedChanges || !canRewrite)
            .help("Commit the staged changes as “squash! \(commit.summary)”, for an autosquash rebase to meld in")
            if !isHead {
                Button("Edit Message…", systemImage: "pencil") {
                    requests.edit = CommitEditRequest(commit: commit, part: .message)
                }
                .disabled(!canRewrite)
            }
            Button("Edit Author…", systemImage: "person.crop.circle") {
                requests.edit = CommitEditRequest(commit: commit, part: .author)
            }
            .disabled(!canRewrite)
        }
    }
}

/// The Repository menu's rebasing commands.
struct RebaseMenuItems: View {
    var model: RepositoryModel?

    var body: some View {
        Button("Rebase Interactively…") {
            if let model, let start = model.interactiveRebaseStart { model.rebasing.interactive = .from(start) }
        }
        .disabled(model?.canStartMerge != true || model?.interactiveRebaseStart == nil)
        Button("Rebase Onto…") { model?.rebasing.onto = RebaseOntoRequest(newBase: "") }
            .disabled(model?.canStartMerge != true || model?.headBranchName == nil)
    }
}

/// A branch menu's item to move the current branch's commits onto it.
struct RebaseOntoMenuItem: View {
    var model: RepositoryModel
    /// The branch, by full name.
    var newBase: String

    var body: some View {
        Button("Rebase \(MenuNames.current(model)) onto Here From…",
               systemImage: "arrow.triangle.branch") {
            model.rebasing.onto = RebaseOntoRequest(newBase: RepositoryModel.displayName(ofReference: newBase))
        }
        .disabled(model.isBusy || model.headBranchName == nil || model.snapshot?.head.branchName == newBase)
        .help("Move the commits after a chosen upstream onto this branch")
    }
}

extension RepositoryModel {
    /// Where the menu's interactive rebase starts: the commit selected in
    /// the history while it shows, otherwise `HEAD`.
    var interactiveRebaseStart: OID? {
        if selection?.historyScope != nil, let selected = history.selection {
            return selected
        }
        return snapshot?.head.target
    }
}
