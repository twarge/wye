import GitKit
import SwiftUI

/// The changed files in the working copy, and the commit being written.
struct WorkingCopyView: View {
    @Bindable var model: RepositoryModel

    @State private var pendingDiscard: DiscardRequest?
    @State private var pendingResolution: ResolutionRequest?
    @State private var isStashing = false

    var body: some View {
        let conflicted = model.workingCopy.conflictedEntries
        List(selection: $model.workingCopy.selection) {
            if conflicted.isEmpty {
                rows(model.workingCopy.entries)
            } else {
                Section("Conflicts") {
                    ForEach(conflicted) { entry in
                        ConflictRow(entry: entry) { side in
                            pendingResolution = ResolutionRequest(path: entry.path, side: side)
                        } markResolved: {
                            Task { await model.markResolved(entry.path) }
                        }
                        .tag(entry.path)
                    }
                }
                Section("Changes") {
                    rows(model.workingCopy.entries.filter { !$0.isConflicted })
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.workingCopy.entries.isEmpty {
                ContentUnavailableView(
                    "No Local Changes",
                    systemImage: "checkmark.circle",
                    description: Text("The working copy matches the last commit.")
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let state = model.snapshot?.state, state != .clean {
                WorkingCopyBanner(model: model, state: state)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CommitComposer(model: model)
        }
        .navigationTitle(model.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Stage All", systemImage: "plus.square.on.square") {
                    Task { await model.stageAll() }
                }
                .disabled(!model.workingCopy.entries.contains { $0.unstaged != nil })
                .help("Stage every change")
                Button("Unstage All", systemImage: "minus.square") {
                    Task { await model.unstageAll() }
                }
                .disabled(!model.workingCopy.hasStagedChanges)
                .help("Unstage every change")
                Menu("Changes", systemImage: "ellipsis.circle") {
                    Button("Stash Changes…", systemImage: "archivebox") {
                        isStashing = true
                    }
                    .disabled(model.workingCopy.entries.isEmpty)
                    Button("Discard All Changes…", systemImage: "trash", role: .destructive) {
                        pendingDiscard = .all
                    }
                    .disabled(!model.workingCopy.hasUnstagedChanges)
                }
                .help("Stash or discard the local changes")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .help("Read the repository again")
            }
        }
        .confirmationDialog(
            pendingDiscard?.title ?? "",
            isPresented: Binding { pendingDiscard != nil } set: { if !$0 { pendingDiscard = nil } },
            titleVisibility: .visible,
            presenting: pendingDiscard
        ) { request in
            Button(request.button, role: .destructive) {
                Task {
                    switch request {
                    case .all: await model.discardAllChanges()
                    case .file(let path, _): await model.discardChanges(in: [path])
                    }
                }
            }
        } message: { request in
            Text(request.message)
        }
        .confirmationDialog(
            pendingResolution?.title ?? "",
            isPresented: Binding { pendingResolution != nil } set: { if !$0 { pendingResolution = nil } },
            titleVisibility: .visible,
            presenting: pendingResolution
        ) { request in
            Button(request.button, role: .destructive) {
                Task { await model.resolveConflict(at: request.path, using: request.side) }
            }
        } message: { request in
            Text(request.message)
        }
        .sheet(isPresented: $isStashing) {
            StashSheet(model: model)
        }
        .task(id: model.viewRequests.pending) {
            // Asked for from the menu bar.
            if model.viewRequests.take(.stashChanges) { isStashing = true }
            if model.viewRequests.take(.discardAllChanges) { pendingDiscard = .all }
        }
    }

    private func rows(_ entries: [StatusEntry]) -> some View {
        ForEach(entries) { entry in
            StatusRow(entry: entry) {
                Task { await model.toggleStaging(of: entry) }
            }
            .tag(entry.path)
            .contextMenu {
                Button(entry.unstaged == nil ? "Unstage" : "Stage", systemImage: entry.unstaged == nil ? "minus.square" : "plus.square") {
                    Task { await model.toggleStaging(of: entry) }
                }
                if entry.unstaged != nil {
                    Divider()
                    Button("Discard Changes…", systemImage: "trash", role: .destructive) {
                        pendingDiscard = .file(entry.path, isUntracked: entry.unstaged == .untracked)
                    }
                }
            }
            .swipeActions(edge: .leading) {
                Button(entry.unstaged == nil ? "Unstage" : "Stage", systemImage: entry.unstaged == nil ? "minus.square" : "plus.square") {
                    Task { await model.toggleStaging(of: entry) }
                }
                .tint(.accentColor)
            }
            .swipeActions(edge: .trailing) {
                if entry.unstaged != nil {
                    // Not destructive in role: that would take the row away
                    // before the discard is confirmed.
                    Button("Discard", systemImage: "trash") {
                        pendingDiscard = .file(entry.path, isUntracked: entry.unstaged == .untracked)
                    }
                    .tint(.red)
                }
            }
        }
    }

    private var subtitle: String {
        let count = model.workingCopy.entries.count
        return "Working Copy (\(count.formatted()) \(count == 1 ? "Change" : "Changes"))"
    }
}

/// Unstaged changes the user asked to throw away, waiting for confirmation.
private enum DiscardRequest {
    case all
    case file(String, isUntracked: Bool)

    var title: String {
        switch self {
        case .all: "Discard All Changes?"
        case .file(let path, _): "Discard Changes to “\(path.splitPath.name)”?"
        }
    }

    var button: String {
        switch self {
        case .all: "Discard All Changes"
        case .file: "Discard Changes"
        }
    }

    var message: String {
        switch self {
        case .all:
            "Every unstaged change is lost, including untracked files. Staged changes are kept. \(Platform.untrackedDiscardNote)"
        case .file(let path, true):
            "“\(path)” is not tracked, so all of it is lost. \(Platform.untrackedDiscardNote)"
        case .file(let path, false):
            "The unstaged changes to “\(path)” are lost and cannot be recovered. Staged changes are kept."
        }
    }
}

/// A conflicted file to resolve by taking one side whole, waiting for confirmation.
private struct ResolutionRequest {
    var path: String
    var side: ConflictSide

    var title: String {
        side == .ours ? "Use Our Version of “\(path.splitPath.name)”?" : "Use Their Version of “\(path.splitPath.name)”?"
    }

    var button: String {
        side == .ours ? "Use Ours" : "Use Theirs"
    }

    var message: String {
        let other = side == .ours ? "their side" : "our side"
        return "The changes from \(other), and any edits made to “\(path)” while resolving, are lost."
    }
}

private struct StatusRow: View {
    var entry: StatusEntry
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: stagingSymbol)
                    .font(.title3)
                    .foregroundStyle(entry.staged == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            // Borderless, so pressing it does not also select the row.
            .buttonStyle(.borderless)
            .accessibilityLabel(entry.unstaged == nil ? "Unstage" : "Stage")
            .accessibilityValue(stagingValue)

            FileLabel(entry: entry)
        }
        .padding(.vertical, 2)
    }

    private var stagingSymbol: String {
        switch (entry.staged, entry.unstaged) {
        case (nil, _): "square"
        case (_, nil): "checkmark.square.fill"
        default: "minus.square.fill"
        }
    }

    private var stagingValue: String {
        switch (entry.staged, entry.unstaged) {
        case (nil, _): "Not staged"
        case (_, nil): "Staged"
        default: "Partly staged"
        }
    }
}

/// A conflicted file, with the ways to resolve it.
private struct ConflictRow: View {
    var entry: StatusEntry
    var resolve: (ConflictSide) -> Void
    var markResolved: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FileLabel(entry: entry)
            Spacer(minLength: 8)
            Menu {
                actions
            } label: {
                Label("Resolve", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Resolve this conflict")
        }
        .padding(.vertical, 2)
        .contextMenu {
            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Use Ours", systemImage: "arrow.left.circle") { resolve(.ours) }
        Button("Use Theirs", systemImage: "arrow.right.circle") { resolve(.theirs) }
        Divider()
        Button("Mark Resolved", systemImage: "checkmark.circle", action: markResolved)
    }
}

/// A file's badge, name and folder.
private struct FileLabel: View {
    var entry: StatusEntry

    var body: some View {
        let path = entry.path.splitPath
        HStack(spacing: 8) {
            FileChangeBadge(change: entry.change)
            VStack(alignment: .leading, spacing: 1) {
                Text(path.name)
                    .lineLimit(1)
                if !path.folder.isEmpty {
                    Text(path.folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
    }
}

/// The fields for a commit's message, and the button that makes it.
private struct CommitComposer: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(model.workingCopy.isAmending ? "Amended Subject" : "Commit Subject", text: $model.workingCopy.subject)
                .font(.headline)
            TextField("Description", text: $model.workingCopy.details, axis: .vertical)
                .lineLimit(2...8)
            HStack {
                if let identity = model.workingCopy.identity {
                    Text("As \(identity.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    SettingsButton {
                        Label("Set your name and email to commit", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.callout)
                    }
                }
                Spacer()
                Toggle("Amend", isOn: Binding {
                    model.workingCopy.isAmending
                } set: { isAmending in
                    Task { await model.setAmending(isAmending) }
                })
                .fixedSize()
                .disabled(!model.workingCopy.isAmending && !model.canAmend)
                .help("Replace the last commit with the staged changes and this message")
                Button(model.workingCopy.isAmending ? "Amend" : "Commit") {
                    Task { await model.commitOrAmend() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.workingCopy.canCommitOrAmend)
            }
        }
        .textFieldStyle(.plain)
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

/// The selected file's changes, staged and not.
struct WorkingCopyDetailView: View {
    var model: RepositoryModel

    @State private var loaded: Loaded?
    @State private var collapsed: Set<String> = []
    @State private var stagedSelection: Set<Int> = []
    @State private var unstagedSelection: Set<Int> = []
    @State private var pendingDiscard: LineDiscard?

    private struct Loaded {
        var path: String
        var staged: FileDiff?
        var unstaged: FileDiff?
    }

    /// Lines of the unstaged diff to throw away, waiting for confirmation.
    private struct LineDiscard {
        var file: FileDiff
        var lines: Set<Int>
        /// Whether these are all of the file's changes, or a hunk's or a few lines'.
        var isWholeHunk: Bool
    }

    /// What to reload on: another file, or the same file after a refresh.
    private struct Trigger: Hashable {
        var path: String?
        var revision: Int
    }

    var body: some View {
        Group {
            if let loaded, loaded.path == model.workingCopy.selection {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let staged = loaded.staged {
                            FileDiffView(
                                file: staged, caption: "Staged", isCollapsed: isCollapsed("staged"),
                                actions: actions(for: staged, side: .staged)
                            )
                        }
                        if let unstaged = loaded.unstaged {
                            FileDiffView(
                                file: unstaged, caption: "Unstaged", isCollapsed: isCollapsed("unstaged"),
                                actions: actions(for: unstaged, side: .unstaged)
                            )
                        }
                    }
                    .padding(.bottom, 20)
                }
            } else {
                ContentUnavailableView("No File Selected", systemImage: "doc.text")
            }
        }
        .task(id: Trigger(path: model.workingCopy.selection, revision: model.revision)) {
            await load()
        }
        .confirmationDialog(
            pendingDiscard.map { $0.isWholeHunk ? "Discard This Hunk?" : "Discard the Selected Lines?" } ?? "",
            isPresented: Binding { pendingDiscard != nil } set: { if !$0 { pendingDiscard = nil } },
            titleVisibility: .visible,
            presenting: pendingDiscard
        ) { request in
            Button("Discard", role: .destructive) {
                Task { await model.discard(lines: request.lines, of: request.file) }
            }
        } message: { request in
            let count = request.file.hunks.flatMap(\.lines).count { request.lines.contains($0.id) }
            Text("\(count == 1 ? "1 changed line" : "\(count.formatted()) changed lines") in “\(request.file.path)” go back to the staged version. The unstaged changes to them are lost and cannot be recovered.")
        }
    }

    /// Stage or unstage controls, and on the unstaged side discard, for a
    /// file whose lines can be told apart.
    private func actions(for file: FileDiff, side: WorkingCopySide) -> DiffLineActions? {
        guard !file.isBinary, file.change != .conflicted else { return nil }
        switch side {
        case .staged:
            return DiffLineActions(verb: "Unstage", systemImage: "minus.square", selection: $stagedSelection) { lines in
                Task { await model.unstage(lines: lines, of: file) }
            }
        case .unstaged:
            return DiffLineActions(verb: "Stage", systemImage: "plus.square", selection: $unstagedSelection) { lines in
                Task { await model.stage(lines: lines, of: file) }
            } discard: { lines in
                let isWholeHunk = file.hunks.contains { $0.changedLineIDs == lines }
                pendingDiscard = LineDiscard(file: file, lines: lines, isWholeHunk: isWholeHunk)
            }
        }
    }

    private func load() async {
        guard let path = model.workingCopy.selection else {
            loaded = nil
            return
        }
        do {
            let staged = try await model.repository.stagedDiff(of: path)
            let unstaged = try await model.repository.unstagedDiff(of: path)
            guard !Task.isCancelled else { return }
            // Line IDs only mean something within the diff they were read
            // from, so a selection does not outlive a change to it.
            if loaded?.path != path || loaded?.staged != staged {
                stagedSelection = []
            }
            if loaded?.path != path || loaded?.unstaged != unstaged {
                unstagedSelection = []
            }
            loaded = Loaded(path: path, staged: staged, unstaged: unstaged)
        } catch {
            model.error = PresentedError(error)
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
