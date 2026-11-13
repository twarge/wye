import GitKit
import SwiftUI

/// What a revision is being chosen for, and so what happens once it is.
enum RevisionPurpose: Hashable {
    case checkOut
    case resetCurrentBranch
    case merge
    case rebase
    /// Compare this revision, as the Compare sheet takes one, with the one chosen.
    case compare(String)
    case pushRevision

    var title: String {
        switch self {
        case .checkOut: "Check Out Revision"
        case .resetCurrentBranch: "Reset to Revision"
        case .merge: "Merge With Revision"
        case .rebase: "Rebase On Revision"
        case .compare(let revision): "Compare “\(revision)” With"
        case .pushRevision: "Push Revision"
        }
    }

    var confirmTitle: String {
        switch self {
        case .checkOut: "Check Out"
        case .resetCurrentBranch, .merge, .rebase, .pushRevision: "Next"
        case .compare: "Compare"
        }
    }

    var explanation: String {
        switch self {
        case .checkOut:
            "A branch is checked out as it is, a remote branch as a local branch that tracks it, "
                + "and a tag or commit with HEAD detached."
        case .resetCurrentBranch: "The next step chooses how far to reset, and says what would be lost."
        case .merge: "The next step chooses how to merge into the current branch."
        case .rebase: "The next step shows what is replayed onto it."
        case .compare: "Shows the commits each side has that the other lacks, and how the files differ."
        case .pushRevision: "The next step chooses the remote and the branch to push the commit to."
        }
    }
}

/// One revision the picker offers.
struct RevisionChoice: Identifiable, Hashable {
    enum Kind: Hashable {
        case head
        case branch
        case remoteBranch
        case tag
        /// Whatever was typed: a hash, `HEAD~2`, any revision git reads.
        case typed
    }

    var kind: Kind
    /// What is resolved and handed on: a full reference name, `HEAD`, or
    /// the text typed.
    var revision: String
    /// The name as people write it.
    var title: String
    var detail: String

    var id: String { revision }

    var systemImage: String {
        switch kind {
        case .head: "smallcircle.filled.circle"
        case .branch: "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        case .typed: "number"
        }
    }

    /// `HEAD`, then the branches, remote branches and tags of a snapshot.
    static func choices(in snapshot: RepositorySnapshot?) -> [RevisionChoice] {
        guard let snapshot else { return [] }
        var choices = [RevisionChoice(kind: .head, revision: "HEAD", title: "HEAD", detail: "The checked-out commit")]
        for branch in snapshot.branches {
            choices.append(RevisionChoice(
                kind: .branch, revision: branch.id, title: branch.name, detail: branch.isHead ? "Current branch" : "Branch"
            ))
        }
        for branch in snapshot.remotes.flatMap(\.branches) where branch.nameWithoutRemote != "HEAD" {
            choices.append(RevisionChoice(kind: .remoteBranch, revision: branch.id, title: branch.name, detail: "Remote branch"))
        }
        for tag in snapshot.tags {
            choices.append(RevisionChoice(kind: .tag, revision: tag.id, title: tag.name, detail: "Tag"))
        }
        return choices
    }

    /// The choices that match what was typed, best first, as quick open
    /// ranks them; with nothing typed, all of them. Unless a name matches
    /// exactly, the text itself comes last, to be read as a revision.
    static func matching(_ query: String, in choices: [RevisionChoice]) -> [RevisionChoice] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return choices }
        let ranked = choices.enumerated()
            .compactMap { offset, choice in
                FuzzyMatcher.match(text, in: choice.title).map { (offset: offset, choice: choice, score: $0.score) }
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.choice.title.count != rhs.choice.title.count { return lhs.choice.title.count < rhs.choice.title.count }
                return lhs.offset < rhs.offset
            }
            .map(\.choice)
        if ranked.contains(where: { $0.title == text }) {
            return ranked
        }
        let typed = RevisionChoice(kind: .typed, revision: text, title: text, detail: "Revision")
        return ranked + [typed]
    }

    /// What the Compare sheet's field shows for it: the short name.
    var compareName: String {
        kind == .typed || kind == .head ? revision : title
    }
}

/// Chooses a branch, tag or commit, with a search field over the names and
/// anything git reads as a revision typed in, then goes on to `purpose`.
struct RevisionPickerSheet: View {
    var model: RepositoryModel
    var purpose: RevisionPurpose

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: RevisionChoice.ID?
    @State private var failure: String?
    @State private var isResolving = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let matches = RevisionChoice.matching(query, in: RevisionChoice.choices(in: model.snapshot))
        SheetStack(purpose.title, placement: .above(inset: 12)) {
            List(selection: $selection) {
                ForEach(matches) { choice in
                    Label {
                        HStack {
                            Text(choice.kind == .typed ? "Use “\(choice.title)”" : choice.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(choice.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: choice.systemImage)
                    }
                    .tag(choice.id)
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Branch, tag or commit", text: $query, prompt: Text("Branch, tag, commit or HEAD~2"))
                        .textFieldStyle(.roundedBorder)
                        .font(.code)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                        .focused($isFieldFocused)
                        .onSubmit { confirm(matches) }
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(12)
                .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text(purpose.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(purpose.confirmTitle) { confirm(matches) }
                        .disabled(isResolving || chosen(in: matches) == nil)
                }
            }
        }
        .sheetMinimumSize(width: 480, height: 440)
        .onChange(of: query) {
            failure = nil
            selection = nil
        }
        .onAppear { isFieldFocused = true }
    }

    /// The selected row, or with none selected the best match.
    private func chosen(in matches: [RevisionChoice]) -> RevisionChoice? {
        matches.first { $0.id == selection } ?? (query.isEmpty ? nil : matches.first)
    }

    private func confirm(_ matches: [RevisionChoice]) {
        guard let choice = chosen(in: matches), !isResolving else { return }
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                let id = try await model.repository.resolveRevision(choice.revision)
                finish(choice, id)
            } catch {
                failure = "“\(choice.title)” is not a branch, tag or commit here."
            }
        }
    }

    /// Goes on with the revision: a sheet that asks more takes this one's
    /// place; anything else runs once this one is gone.
    private func finish(_ choice: RevisionChoice, _ id: OID) {
        // A typed revision is pinned to the commit it named just now.
        let revision = choice.kind == .typed ? id.hex : choice.revision
        switch purpose {
        case .checkOut:
            dismiss()
            Task {
                switch choice.kind {
                case .branch: await model.checkOutBranch(choice.revision)
                case .remoteBranch: await model.trackRemoteBranch(choice.revision)
                case .tag: await model.checkOutTag(choice.revision)
                case .head, .typed: await model.checkOutCommit(id)
                }
            }
        case .resetCurrentBranch:
            model.present(.reset(to: id))
        case .merge:
            model.present(.merge(revision))
        case .rebase:
            model.present(.rebase(onto: revision))
        case .compare(let other):
            model.present(.compare(from: other, to: choice.compareName))
        case .pushRevision:
            model.present(.pushRevision(id))
        }
    }
}
