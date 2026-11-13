import GitKit
import SwiftUI

extension WorkingTreeComparison {
    var title: String {
        switch self {
        case .workingTreeToHead: "Working Tree to HEAD"
        case .workingTreeToIndex: "Working Tree to Index"
        case .indexToHead: "Index to HEAD"
        }
    }

    /// The picker's short name.
    var shortTitle: String {
        switch self {
        case .workingTreeToHead: "All Changes"
        case .workingTreeToIndex: "Unstaged"
        case .indexToHead: "Staged"
        }
    }

    var explanation: String {
        switch self {
        case .workingTreeToHead: "Everything not yet committed, staged or not, as git diff HEAD shows it."
        case .workingTreeToIndex: "What is not staged, as git diff shows it."
        case .indexToHead: "What is staged and would be committed, as git diff --cached shows it."
        }
    }
}

/// The working tree, the index and `HEAD` compared as a whole, or the
/// working tree and a commit: every file that differs, with its diff.
/// Untracked files are left out, as git leaves them out of these diffs.
struct WorkingTreeCompareView: View {
    var model: RepositoryModel
    /// The commit the working tree is compared with, in place of the
    /// comparisons the picker offers.
    private var commit: OID?

    @Environment(\.dismiss) private var dismiss
    @State private var comparison: WorkingTreeComparison
    @State private var files: [FileDiff]?
    @State private var collapsed: Set<String> = []
    @State private var failure: String?
    /// The comparison the folds were set for, so a refresh keeps them.
    @State private var folded: WorkingTreeComparison?

    init(model: RepositoryModel, comparison: WorkingTreeComparison) {
        self.model = model
        _comparison = State(initialValue: comparison)
    }

    /// Compares the working tree, staged or not, with a commit.
    init(model: RepositoryModel, comparingWorkingTreeTo commit: OID) {
        self.init(model: model, comparison: .workingTreeToHead)
        self.commit = commit
    }

    var body: some View {
        SheetStack(title, placement: .above(inset: 16)) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        if commit == nil {
                            Picker("Compare", selection: $comparison) {
                                ForEach(WorkingTreeComparison.allCases) { comparison in
                                    Text(comparison.shortTitle).tag(comparison)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let failure {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        } else if let files {
                            Text(files.isEmpty
                                 ? "No differences"
                                 : "\(files.count.formatted()) \(files.count == 1 ? "file differs" : "files differ")")
                                .font(.headline)
                                .padding(.top, 8)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(16)
                    ForEach(files ?? []) { file in
                        FileDiffView(file: file, isCollapsed: isCollapsed(file.id))
                    }
                }
                .padding(.bottom, 20)
            }
            .findInDiffs((files ?? []).map { FindableDiff($0) })
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetMinimumSize(width: 640, height: 520)
        .task(id: Key(comparison: comparison, revision: model.revision)) {
            await load()
        }
    }

    private struct Key: Hashable {
        var comparison: WorkingTreeComparison
        var revision: Int
    }

    private var title: String {
        commit.map { "Working Tree to \($0.abbreviated())" } ?? comparison.title
    }

    private var explanation: String {
        guard let commit else { return comparison.explanation }
        let hash = commit.abbreviated()
        return "Everything in the working tree that differs from \(hash), staged or not, as git diff \(hash) shows it."
    }

    private func load() async {
        let comparison = comparison
        let options = DiffPreferences.shared.options
        do {
            let files = if let commit {
                try await model.repository.changes(since: commit, options: options)
            } else {
                try await model.repository.changes(in: comparison, options: options)
            }
            guard comparison == self.comparison else { return }
            // Long lists start folded, so the list of files shows first.
            if folded != comparison {
                collapsed = files.count > 10 ? Set(files.map(\.id)) : []
                folded = comparison
            }
            self.files = files
            failure = nil
        } catch {
            files = nil
            failure = error.localizedDescription
        }
    }

    private func isCollapsed(_ id: String) -> Binding<Bool> {
        Binding {
            collapsed.contains(id)
        } set: { isCollapsed in
            if isCollapsed {
                collapsed.insert(id)
            } else {
                collapsed.remove(id)
            }
        }
    }
}
