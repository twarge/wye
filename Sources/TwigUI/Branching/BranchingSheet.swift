import GitKit
import SwiftUI

/// A sheet that a branching action asks for. Sidebar and history menus set
/// `RepositoryModel.branchingSheet`; the repository window shows it, so it
/// does not depend on the row that asked staying on screen.
enum BranchingSheet: Identifiable, Hashable {
    /// Merge a branch, remote branch or tag, by full reference name, into `HEAD`.
    case merge(String)
    /// Rebase `HEAD`'s branch onto a branch, by full reference name.
    case rebase(onto: String)
    case renameBranch(String)
    case deleteBranch(String)
    case deleteTag(String)
    case newBranch(at: OID)
    case newTag(at: OID)
    case reset(to: OID)

    var id: Self { self }
}

extension View {
    /// Shows the model's branching sheets.
    func branchingSheets(_ model: RepositoryModel) -> some View {
        modifier(BranchingSheets(model: model))
    }
}

private struct BranchingSheets: ViewModifier {
    @Bindable var model: RepositoryModel

    func body(content: Content) -> some View {
        content.sheet(item: $model.branchingSheet) { sheet in
            switch sheet {
            case .merge(let reference):
                MergeSheet(model: model, reference: reference)
            case .rebase(let onto):
                RebaseSheet(model: model, onto: onto)
            case .renameBranch(let branch):
                RenameBranchSheet(model: model, branch: branch)
            case .deleteBranch(let branch):
                DeleteBranchSheet(model: model, branch: branch)
            case .deleteTag(let tag):
                DeleteTagSheet(model: model, tag: tag)
            case .newBranch(let commit):
                NewBranchSheet(model: model, startingPoint: commit)
            case .newTag(let commit):
                NewTagSheet(model: model, commit: commit)
            case .reset(let commit):
                ResetSheet(model: model, commit: commit)
            }
        }
    }
}

/// The frame every branching sheet shares: a form with Cancel and one
/// confirming button.
struct BranchingSheetForm<Content: View>: View {
    var title: String
    var confirmTitle: String
    var isDestructive = false
    var canConfirm = true
    var confirm: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                content
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, role: isDestructive ? .destructive : nil) {
                        dismiss()
                        confirm()
                    }
                    .disabled(!canConfirm)
                }
            }
        }
        .frame(minWidth: 400)
    }
}
