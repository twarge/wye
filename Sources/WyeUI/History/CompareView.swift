import GitKit
import SwiftUI

/// Compares two commits, branches or tags: the commits each has that the
/// other lacks, and how the files differ from the first to the second.
struct CompareView: View {
    var model: RepositoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var left: String
    @State private var right: String
    @State private var comparison: Comparison?
    @State private var isComparing = false
    @State private var collapsed: Set<String> = []
    /// Shown in the sheet, which would cover the window's own notices.
    @State private var failure: String?

    /// Starts from `base` against `HEAD`.
    init(model: RepositoryModel, base: OID?) {
        self.init(model: model, from: base?.hex ?? "HEAD", to: "HEAD")
    }

    /// Starts from two revisions, comparing them at once.
    init(model: RepositoryModel, from: String, to: String) {
        self.model = model
        _left = State(initialValue: from)
        _right = State(initialValue: to)
        comparesAtOnce = from != to
    }

    /// Whether the sheet compares as it opens, having been given both sides.
    private let comparesAtOnce: Bool

    var body: some View {
        SheetStack("Compare", placement: .above(inset: 16)) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    fields
                    if let comparison {
                        results(comparison)
                    }
                }
                .padding(.bottom, 20)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetMinimumSize(width: 640, height: 520)
        // A sheet: the window's are outside it.
        .diffSupport(model)
        .task {
            if comparesAtOnce { await compare() }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            revisionField("From", text: $left)
            revisionField("To", text: $right)
            HStack {
                Button("Swap", systemImage: "arrow.up.arrow.down") {
                    (left, right) = (right, left)
                    Task { await compare() }
                }
                Spacer()
                if isComparing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Compare") {
                    Task { await compare() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isComparing || left.trimmingCharacters(in: .whitespaces).isEmpty
                          || right.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
    }

    private func revisionField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            TextField(title, text: text, prompt: Text("Branch, tag or commit"))
                .textFieldStyle(.roundedBorder)
                .font(.code)
                .autocorrectionDisabled()
                .onSubmit { Task { await compare() } }
            Menu {
                Button("HEAD") { text.wrappedValue = "HEAD" }
                if let snapshot = model.snapshot {
                    Section("Branches") {
                        ForEach(snapshot.branches) { branch in
                            Button(branch.name) { text.wrappedValue = branch.name }
                        }
                    }
                    let remoteBranches = snapshot.remotes.flatMap(\.branches).filter { $0.nameWithoutRemote != "HEAD" }
                    if !remoteBranches.isEmpty {
                        Section("Remote Branches") {
                            ForEach(remoteBranches) { branch in
                                Button(branch.name) { text.wrappedValue = branch.name }
                            }
                        }
                    }
                    if !snapshot.tags.isEmpty {
                        Section("Tags") {
                            ForEach(snapshot.tags) { tag in
                                Button(tag.name) { text.wrappedValue = tag.name }
                            }
                        }
                    }
                }
            } label: {
                Label("References", systemImage: "arrow.triangle.branch")
            }
            .fixedSize()
            .help("Choose a branch or tag")
        }
    }

    @ViewBuilder
    private func results(_ comparison: Comparison) -> some View {
        commitSection("Only in \(left)", commits: comparison.onlyLeft, total: comparison.leftCount)
        commitSection("Only in \(right)", commits: comparison.onlyRight, total: comparison.rightCount)
        Text(comparison.files.isEmpty
             ? "No differences in files"
             : "\(comparison.files.count.formatted()) \(comparison.files.count == 1 ? "file differs" : "files differ")")
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.top, 16)
        ForEach(comparison.files) { file in
            FileDiffView(file: file, isCollapsed: isCollapsed(file.id))
        }
        .diffPackages(comparison.files)
    }

    @ViewBuilder
    private func commitSection(_ title: String, commits: [Commit], total: Int) -> some View {
        Text("\(title) (\(total.formatted()))")
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
        if commits.isEmpty {
            Text("None")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        ForEach(commits) { commit in
            Button {
                model.showInHistory(commit.id)
                dismiss()
            } label: {
                SearchResultRow(commit: commit, labels: model.refLabels[commit.id] ?? [])
                    .padding(.horizontal, 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show this commit in the history")
        }
        if total > commits.count {
            Text("And \((total - commits.count).formatted()) more")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }

    private func compare() async {
        isComparing = true
        failure = nil
        defer { isComparing = false }
        do {
            let repository = model.repository
            let leftID = try await repository.resolveRevision(left)
            let rightID = try await repository.resolveRevision(right)
            let comparison = try await repository.compare(leftID, rightID)
            // Long diffs start folded, so the commits stay in view.
            collapsed = comparison.files.count > 10 ? Set(comparison.files.map(\.id)) : []
            self.comparison = comparison
        } catch {
            comparison = nil
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
