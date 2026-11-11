import Foundation
import GitKit

/// What is dragged within a repository window, carried as plain text so it
/// is also useful dropped elsewhere: commits as their hashes, one a line,
/// and a branch, remote branch or tag as its full reference name.
enum SidebarDragPayload: Hashable {
    case commits([OID])
    case reference(String)

    static func text(for commits: [OID]) -> String {
        commits.map(\.hex).joined(separator: "\n")
    }

    /// Reads dropped text back, or `nil` when it is neither.
    init?(_ strings: [String]) {
        let lines = strings.flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        if lines.count == 1, let name = lines.first,
           ["refs/heads/", "refs/remotes/", "refs/tags/"].contains(where: name.hasPrefix) {
            self = .reference(name)
            return
        }
        let ids = lines.compactMap(OID.init(hex:))
        guard ids.count == lines.count else { return nil }
        self = .commits(ids)
    }
}

/// Where something can be dropped in the sidebar.
enum SidebarDropTarget: Hashable {
    /// A local branch, by full reference name.
    case branch(String)
    case workingCopy
}

/// What a drop offers: never done on the drop itself, but asked about, each
/// choice leading to the action the menus have.
struct SidebarDropProposal: Identifiable, Hashable {
    enum Action: Hashable {
        /// Cherry-pick onto the current branch, newest first as listed.
        case cherryPick([OID])
        /// Check out a branch, then cherry-pick onto it.
        case checkOutAndCherryPick(branch: String, [OID])
        /// The merge sheet, into the current branch.
        case merge(String)
        /// The rebase sheet, for the current branch.
        case rebase(onto: String)
        /// Check out `branch`, then the merge sheet for `merging` into it.
        case checkOutAndMerge(branch: String, merging: String)
        /// Check out `branch`, then the rebase sheet onto `onto`.
        case checkOutAndRebase(branch: String, onto: String)
        case checkOutBranch(String)
        case checkOutTag(String)
        /// Check out a remote branch as a local branch that tracks it.
        case trackRemoteBranch(String)
        case checkOutCommit(OID)
    }

    struct Choice: Hashable, Identifiable {
        var title: String
        var action: Action

        var id: Self { self }
    }

    var title: String
    var choices: [Choice]

    var id: Self { self }

    /// What dropping `payload` on `target` offers, or `nil` when nothing.
    static func make(_ payload: SidebarDragPayload, onto target: SidebarDropTarget,
                     in snapshot: RepositorySnapshot) -> SidebarDropProposal? {
        let current = snapshot.head.branchName
        switch (payload, target) {
        case (.commits(let ids), .branch(let branch)):
            // A branch checked out in another worktree cannot be checked out here.
            guard let local = snapshot.branches.first(where: { $0.id == branch }) else { return nil }
            let what = ids.count == 1 ? "“\(ids[0].abbreviated())”" : "\(ids.count) Commits"
            let name = quoted(branch)
            if branch == current {
                return SidebarDropProposal(title: "Cherry-pick onto \(name)?", choices: [
                    Choice(title: "Cherry-Pick \(what) onto \(name)", action: .cherryPick(ids))
                ])
            }
            guard local.worktreePath == nil else { return nil }
            return SidebarDropProposal(title: "Cherry-pick onto \(name)?", choices: [
                Choice(title: "Check Out \(name) and Cherry-Pick \(what)",
                       action: .checkOutAndCherryPick(branch: branch, ids))
            ])

        case (.reference(let dragged), .branch(let branch)):
            guard dragged != branch, let local = snapshot.branches.first(where: { $0.id == branch }) else { return nil }
            let draggedName = quoted(dragged), name = quoted(branch)
            let draggedIsLocal = dragged.hasPrefix("refs/heads/")
            var choices: [Choice] = []
            if branch == current {
                choices.append(Choice(title: "Merge \(draggedName) into \(name)…", action: .merge(dragged)))
                choices.append(Choice(title: "Rebase \(name) onto \(draggedName)…", action: .rebase(onto: dragged)))
            } else if dragged == current {
                choices.append(Choice(title: "Rebase \(draggedName) onto \(name)…", action: .rebase(onto: branch)))
                if local.worktreePath == nil {
                    choices.append(Choice(title: "Check Out \(name) and Merge \(draggedName) into It…",
                                          action: .checkOutAndMerge(branch: branch, merging: dragged)))
                }
            } else {
                if local.worktreePath == nil {
                    choices.append(Choice(title: "Check Out \(name) and Merge \(draggedName) into It…",
                                          action: .checkOutAndMerge(branch: branch, merging: dragged)))
                }
                let draggedBranch = snapshot.branches.first { $0.id == dragged }
                if draggedIsLocal, draggedBranch?.worktreePath == nil {
                    choices.append(Choice(title: "Check Out \(draggedName) and Rebase It onto \(name)…",
                                          action: .checkOutAndRebase(branch: dragged, onto: branch)))
                }
            }
            guard !choices.isEmpty else { return nil }
            return SidebarDropProposal(title: "Bring \(draggedName) and \(name) together?", choices: choices)

        case (.reference(let dragged), .workingCopy):
            let name = quoted(dragged)
            let action: Action
            if dragged.hasPrefix("refs/heads/") {
                guard dragged != current,
                      snapshot.branches.first(where: { $0.id == dragged })?.worktreePath == nil else { return nil }
                action = .checkOutBranch(dragged)
            } else if dragged.hasPrefix("refs/tags/") {
                action = .checkOutTag(dragged)
            } else {
                action = .trackRemoteBranch(dragged)
            }
            return SidebarDropProposal(title: "Check out \(name)?", choices: [Choice(title: "Check Out \(name)", action: action)])

        case (.commits(let ids), .workingCopy):
            guard ids.count == 1, let id = ids.first, id != snapshot.head.target else { return nil }
            let name = "“\(id.abbreviated())”"
            return SidebarDropProposal(title: "Check out \(name)?", choices: [
                Choice(title: "Check Out \(name) with HEAD Detached", action: .checkOutCommit(id))
            ])
        }
    }

    /// A reference as the menus name it: `“main”` for `refs/heads/main`.
    private static func quoted(_ reference: String) -> String {
        var name = reference
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return "“\(name)”"
    }
}

extension RepositoryModel {
    /// Does what a drop's choice says, through the same actions and sheets
    /// as the menus.
    func performDrop(_ action: SidebarDropProposal.Action) async {
        switch action {
        case .cherryPick(let ids):
            await cherryPick(ids)
        case .checkOutAndCherryPick(let branch, let ids):
            await checkOutBranch(branch)
            if snapshot?.head.branchName == branch { await cherryPick(ids) }
        case .merge(let reference):
            present(.merge(reference))
        case .rebase(let onto):
            present(.rebase(onto: onto))
        case .checkOutAndMerge(let branch, let merging):
            await checkOutBranch(branch)
            if snapshot?.head.branchName == branch { present(.merge(merging)) }
        case .checkOutAndRebase(let branch, let onto):
            await checkOutBranch(branch)
            if snapshot?.head.branchName == branch { present(.rebase(onto: onto)) }
        case .checkOutBranch(let branch):
            await checkOutBranch(branch)
        case .checkOutTag(let tag):
            await checkOutTag(tag)
        case .trackRemoteBranch(let branch):
            await trackRemoteBranch(branch)
        case .checkOutCommit(let id):
            await checkOutCommit(id)
        }
    }
}
