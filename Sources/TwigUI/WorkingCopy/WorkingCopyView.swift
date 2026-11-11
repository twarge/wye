import GitKit
import SwiftUI

/// The changed files in the working copy, and the commit being written.
struct WorkingCopyView: View {
    @Bindable var model: RepositoryModel

    @State private var pendingDiscard: DiscardRequest?
    @State private var pendingResolution: ResolutionRequest?
    @State private var resolving: ConflictTarget?
    @State private var isStashing = false
    /// Files to stash on their own, waiting for the stash sheet.
    @State private var stashingFiles: StashFiles?
    /// A rule to edit in the ignore rules before adding it.
    @State private var customIgnore: CustomIgnoreRequest?
    @State private var isEditingIgnoreRules = false
    @State private var filter = ""
    /// Folders of the tree the user folded, by their IDs.
    @State private var collapsedFolders: Set<String> = []
    /// The files left out of the list unless asked for, read on refresh.
    @State private var hidden = HiddenFiles()

    @AppStorage("workingCopy.layout") private var layout = FileListLayout.list
    @AppStorage("workingCopy.sort") private var sort = FileListSort.path
    @AppStorage("workingCopy.showsIgnored") private var showsIgnored = false
    @AppStorage("workingCopy.showsAssumeUnchanged") private var showsAssumeUnchanged = false

    /// Ignored and assumed-unchanged files, which status leaves out.
    private struct HiddenFiles {
        var ignored: [String] = []
        var assumeUnchanged: [String] = []
    }

    private struct HiddenTrigger: Hashable {
        var revision: Int
        var showsIgnored: Bool
        var showsAssumeUnchanged: Bool
    }

    var body: some View {
        let conflicted = FileList.filtered(model.workingCopy.conflictedEntries, by: filter)
        let changes = FileList.filtered(model.workingCopy.entries.filter { !$0.isConflicted }, by: filter)
        let ignored = showsIgnored ? filteredPaths(hidden.ignored) : []
        let assumed = showsAssumeUnchanged ? filteredPaths(hidden.assumeUnchanged) : []
        List(selection: $model.workingCopy.selectedSet) {
            if conflicted.isEmpty && ignored.isEmpty && assumed.isEmpty {
                changeRows(changes)
            } else {
                if !conflicted.isEmpty {
                    Section("Conflicts") {
                        ForEach(conflicted) { entry in
                            ConflictRow(entry: entry) { side in
                                pendingResolution = ResolutionRequest(path: entry.path, side: side)
                            } markResolved: {
                                Task { await model.markResolved(entry.path) }
                            } openResolver: {
                                resolving = ConflictTarget(path: entry.path)
                            }
                            .tag(entry.path)
                        }
                    }
                }
                if !changes.isEmpty {
                    Section("Changes") {
                        changeRows(changes)
                    }
                }
                if !assumed.isEmpty {
                    Section("Assumed Unchanged") {
                        ForEach(assumed, id: \.self) { path in
                            HiddenFileRow(path: path, systemImage: "lock")
                                .contextMenu {
                                    Button("Stop Assuming Unchanged", systemImage: "lock.open") {
                                        Task { await model.setAssumeUnchanged(false, for: [path]) }
                                    }
                                    WorkingCopyHiddenFileMenu(model: model, path: path)
                                }
                        }
                    }
                }
                if !ignored.isEmpty {
                    Section("Ignored") {
                        ForEach(ignored, id: \.self) { path in
                            HiddenFileRow(path: path, systemImage: "eye.slash")
                                .contextMenu {
                                    WorkingCopyHiddenFileMenu(model: model, path: path)
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.workingCopy.entries.isEmpty && ignored.isEmpty && assumed.isEmpty {
                ContentUnavailableView(
                    "No Local Changes",
                    systemImage: "checkmark.circle",
                    description: Text("The working copy matches the last commit.")
                )
            } else if conflicted.isEmpty && changes.isEmpty && ignored.isEmpty && assumed.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let state = model.snapshot?.state, state != .clean {
                    WorkingCopyBanner(model: model, state: state)
                }
                // The commit comes first, above the files it will take.
                CommitComposer(model: model)
                FileListControls(filter: $filter, layout: $layout, sort: $sort)
            }
        }
        .task(id: HiddenTrigger(
            revision: model.revision, showsIgnored: showsIgnored, showsAssumeUnchanged: showsAssumeUnchanged
        )) {
            await loadHiddenFiles()
        }
        .sheet(isPresented: $isEditingIgnoreRules) {
            IgnoreRulesSheet(model: model)
        }
        .sheet(item: $customIgnore) { request in
            IgnoreRulesSheet(model: model, initial: request)
        }
        .environment(\.requestCustomIgnore, RequestCustomIgnoreAction { customIgnore = $0 })
        .navigationTitle(model.name)
        .navigationSubtitle(subtitle)
        // A large title would sit behind the commit fields pinned at the top.
        .toolbarTitleDisplayMode(.inline)
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
                    Button("Stash Selected Files…", systemImage: "archivebox") {
                        stashingFiles = StashFiles(paths: model.workingCopy.selectedChangedPaths)
                    }
                    .disabled(model.workingCopy.selectedChangedPaths.isEmpty)
                    Menu("Save as Patch", systemImage: "doc.badge.arrow.up") {
                        Button("All Changes…") { Task { await model.savePatch(.all) } }
                        Button("Staged Changes…") { Task { await model.savePatch(.staged) } }
                            .disabled(!model.workingCopy.hasStagedChanges)
                        Button("Selected Files…") {
                            Task { await model.savePatch(.files(model.workingCopy.selectedChangedPaths)) }
                        }
                        .disabled(model.workingCopy.selectedChangedPaths.isEmpty)
                    }
                    .disabled(model.workingCopy.entries.isEmpty)
                    Button("Discard All Changes…", systemImage: "trash", role: .destructive) {
                        pendingDiscard = .all
                    }
                    .disabled(!model.workingCopy.hasUnstagedChanges)
                    Section {
                        Toggle("Show Ignored Files", systemImage: "eye.slash", isOn: $showsIgnored)
                        Toggle("Show Assumed-Unchanged Files", systemImage: "lock", isOn: $showsAssumeUnchanged)
                    }
                    Section {
                        Button("Ignore Rules…", systemImage: "list.bullet.rectangle") {
                            isEditingIgnoreRules = true
                        }
                    }
                }
                .help("Stash or discard the local changes, and choose which files show")
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
        .sheet(item: $stashingFiles) { files in
            StashSheet(model: model, paths: files.paths)
        }
        .conflictResolver(for: $resolving, model: model)
        .task(id: model.viewRequests.pending) {
            // Asked for from the menu bar.
            if model.viewRequests.take(.stashChanges) { isStashing = true }
            if model.viewRequests.take(.discardAllChanges) { pendingDiscard = .all }
        }
    }

    /// The changed files, as a list or as a tree, in the chosen order.
    @ViewBuilder
    private func changeRows(_ entries: [StatusEntry]) -> some View {
        switch layout {
        case .list:
            ForEach(FileList.sorted(entries, by: sort)) { entry in
                row(entry, depth: 0, showsFolder: true)
            }
        case .tree:
            let rows = FileList.rows(FileList.tree(entries, sort: sort), collapsed: filter.isEmpty ? collapsedFolders : [])
            ForEach(rows) { row in
                switch row.node.kind {
                case .folder(let entries):
                    FolderRow(
                        node: row.node, depth: row.depth, isCollapsed: filter.isEmpty && collapsedFolders.contains(row.id)
                    ) {
                        if collapsedFolders.contains(row.id) {
                            collapsedFolders.remove(row.id)
                        } else {
                            collapsedFolders.insert(row.id)
                        }
                    } toggleStaging: {
                        Task { await model.toggleStaging(of: entries) }
                    }
                    .contextMenu {
                        let state = StagingState(entries)
                        Button(state == .staged ? "Unstage Folder" : "Stage Folder",
                               systemImage: state == .staged ? "minus.square" : "plus.square") {
                            Task { await model.toggleStaging(of: entries) }
                        }
                        Section {
                            let paths = entries.filter { !$0.isConflicted }.map(\.path)
                            Button("Stash Folder…", systemImage: "archivebox") {
                                stashingFiles = StashFiles(paths: paths)
                            }
                            Button("Save Folder as Patch…", systemImage: "doc.badge.arrow.up") {
                                Task { await model.savePatch(.files(paths)) }
                            }
                        }
                        .disabled(entries.allSatisfy(\.isConflicted))
                        WorkingCopyFolderMenu(model: model, node: row.node)
                    }
                case .file(let entry):
                    self.row(entry, depth: row.depth, showsFolder: false)
                }
            }
        }
    }

    private func filteredPaths(_ paths: [String]) -> [String] {
        let words = filter.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return paths }
        return paths.filter { path in
            words.allSatisfy { path.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private func loadHiddenFiles() async {
        var files = HiddenFiles()
        do {
            if showsIgnored {
                files.ignored = try await model.repository.ignoredPaths()
            }
            if showsAssumeUnchanged {
                files.assumeUnchanged = try await model.repository.assumeUnchangedPaths()
            }
        } catch {
            model.error = PresentedError(error)
        }
        guard !Task.isCancelled else { return }
        hidden = files
    }

    private func row(_ entry: StatusEntry, depth: Int, showsFolder: Bool) -> some View {
        StatusRow(entry: entry, showsFolder: showsFolder) {
            Task { await model.toggleStaging(of: entry) }
        }
        .padding(.leading, CGFloat(depth) * FolderRow.indent)
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
            Section {
                let paths = menuTargets(for: entry)
                Button(paths.count == 1 ? "Stash…" : "Stash \(paths.count.formatted()) Files…", systemImage: "archivebox") {
                    stashingFiles = StashFiles(paths: paths)
                }
                Button(paths.count == 1 ? "Save as Patch…" : "Save \(paths.count.formatted()) Files as Patch…",
                       systemImage: "doc.badge.arrow.up") {
                    Task { await model.savePatch(.files(paths)) }
                }
            }
            Divider()
            WorkingCopyFileMenu(model: model, entry: entry)
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

    /// What a row's menu acts on: every selected file when the row is one
    /// of several selected, otherwise the row's file.
    private func menuTargets(for entry: StatusEntry) -> [String] {
        let selected = model.workingCopy.selectedChangedPaths
        return selected.count > 1 && selected.contains(entry.path) ? selected : [entry.path]
    }

    private var subtitle: String {
        let count = model.workingCopy.entries.count
        return "Working Copy (\(count.formatted()) \(count == 1 ? "Change" : "Changes"))"
    }
}

/// Files to stash on their own.
private struct StashFiles: Identifiable {
    let id = UUID()
    var paths: [String]
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
    var showsFolder = true
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

            FileLabel(entry: entry, showsFolder: showsFolder)
        }
        .padding(.vertical, 2)
    }

    private var stagingSymbol: String {
        StagingState([entry]).symbol
    }

    private var stagingValue: String {
        StagingState([entry]).accessibilityValue
    }
}

extension StagingState {
    var symbol: String {
        switch self {
        case .unstaged: "square"
        case .staged: "checkmark.square.fill"
        case .partlyStaged: "minus.square.fill"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .unstaged: "Not staged"
        case .staged: "Staged"
        case .partlyStaged: "Partly staged"
        }
    }
}

/// A folder of the tree of changed files: it folds, and its checkbox stages
/// or unstages everything under it.
private struct FolderRow: View {
    static let indent: CGFloat = 16

    var node: FileTreeNode
    var depth: Int
    var isCollapsed: Bool
    var toggleCollapsed: () -> Void
    var toggleStaging: () -> Void

    var body: some View {
        let state = StagingState(node.entries)
        HStack(spacing: 8) {
            Button(action: toggleStaging) {
                Image(systemName: state.symbol)
                    .font(.title3)
                    .foregroundStyle(state == .unstaged ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(state == .staged ? "Unstage Folder" : "Stage Folder")
            .accessibilityValue(state.accessibilityValue)

            Button(action: toggleCollapsed) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(isCollapsed ? .zero : .degrees(90))
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(node.entries.count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(node.name)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityHint(isCollapsed ? "Shows the files in this folder" : "Hides the files in this folder")
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(depth) * Self.indent)
    }
}

/// An ignored or assumed-unchanged file, shown on request.
private struct HiddenFileRow: View {
    var path: String
    var systemImage: String

    var body: some View {
        let parts = path.hasSuffix("/") ? (name: String(path.dropLast()).splitPath.name + "/", folder: String(path.dropLast()).splitPath.folder) : path.splitPath
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(parts.name)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                if !parts.folder.isEmpty {
                    Text(parts.folder)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The search field, the list or tree switch and the order of the files.
private struct FileListControls: View {
    @Binding var filter: String
    @Binding var layout: FileListLayout
    @Binding var sort: FileListSort

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                if !filter.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { filter = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: .rect(cornerRadius: 6))

            Picker("Layout", selection: $layout) {
                ForEach(FileListLayout.allCases) { layout in
                    Label(layout.title, systemImage: layout.systemImage).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show the files as a list or under their folders")

            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(FileListSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort the files")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// A conflicted file, with the ways to resolve it.
private struct ConflictRow: View {
    var entry: StatusEntry
    var resolve: (ConflictSide) -> Void
    var markResolved: () -> Void
    var openResolver: () -> Void

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
        Button("Resolve…", systemImage: "arrow.triangle.merge", action: openResolver)
        Divider()
        Button("Use Ours", systemImage: "arrow.left.circle") { resolve(.ours) }
        Button("Use Theirs", systemImage: "arrow.right.circle") { resolve(.theirs) }
        Divider()
        Button("Mark Resolved", systemImage: "checkmark.circle", action: markResolved)
    }
}

/// A file's badge, name and folder.
private struct FileLabel: View {
    var entry: StatusEntry
    var showsFolder = true

    var body: some View {
        let path = entry.path.splitPath
        HStack(spacing: 8) {
            FileChangeBadge(change: entry.change)
            VStack(alignment: .leading, spacing: 1) {
                Text(path.name)
                    .lineLimit(1)
                if showsFolder, !path.folder.isEmpty {
                    Text(path.folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                // A submodule says what changed in it, as git's status does.
                if let summary = entry.submodule?.summary {
                    Text("Submodule: \(summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The fields for a commit's message, and the button that makes it.
private struct CommitComposer: View {
    @Bindable var model: RepositoryModel

    /// What recent history offers the fields' completions.
    @State private var sources = CommitCompletionSources()

    var body: some View {
        let context = CompletionContext(paths: model.workingCopy.entries.map(\.path), sources: sources)
        VStack(alignment: .leading, spacing: 8) {
            CompletingField(text: $model.workingCopy.subject, isSubject: true, context: context) { selection in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField(
                        model.workingCopy.isAmending ? "Amended Subject" : "Commit Subject",
                        text: $model.workingCopy.subject, selection: selection
                    )
                    .font(.headline)
                    SubjectLengthMarker(subject: model.workingCopy.subject)
                    MessageMenu(model: model)
                }
            }
            CompletingField(text: $model.workingCopy.details, isSubject: false, context: context) { selection in
                DescriptionEditor(text: $model.workingCopy.details, selection: selection)
            }
            HStack {
                AuthorMenu(model: model)
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
                    Task { await model.commitFromComposer() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.workingCopy.canCommitOrAmend)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .task(id: model.snapshot?.head) {
            sources = (try? await model.repository.commitCompletionSources()) ?? CommitCompletionSources()
        }
    }
}

/// The commit's description: a text view of several lines, where Return
/// starts a new line, dressed as the system's bordered text field.
private struct DescriptionEditor: View {
    @Binding var text: String
    var selection: Binding<TextSelection?>

    var body: some View {
        TextEditor(text: $text, selection: selection)
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 64, idealHeight: 64, maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Description")
                        .foregroundStyle(.placeholder)
                        .padding(Platform.textEditorPlaceholderInsets)
                        .allowsHitTesting(false)
                }
            }
            .padding(Platform.textEditorFieldPadding)
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator)
            }
            .accessibilityLabel("Description")
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
    /// Lines of the unstaged diff to stash, waiting for a message.
    @State private var pendingStash: LineStash?
    @State private var stashMessage = ""

    private struct LineStash {
        var file: FileDiff
        var lines: Set<Int>
    }

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

    /// What to reload on: another file, the same file after a refresh, or
    /// other diff options.
    private struct Trigger: Hashable {
        var path: String?
        var revision: Int
        var options: DiffOptions
    }

    var body: some View {
        Group {
            if let loaded, loaded.path == model.workingCopy.selection {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !DiffPreferences.shared.options.isExact, loaded.staged != nil || loaded.unstaged != nil {
                            Label(
                                "Whitespace changes are hidden, so hunks and lines cannot be staged one by one. Stage the whole file, or show whitespace changes in Settings.",
                                systemImage: "info.circle"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                        }
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
                .findInDiffs([
                    loaded.staged.map { FindableDiff($0, caption: "Staged") },
                    loaded.unstaged.map { FindableDiff($0, caption: "Unstaged") }
                ].compactMap(\.self))
            } else {
                ContentUnavailableView("No File Selected", systemImage: "doc.text")
            }
        }
        .task(id: Trigger(path: model.workingCopy.selection, revision: model.revision, options: DiffPreferences.shared.options)) {
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
            let lines = count == 1 ? "1 changed line" : "\(count.formatted()) changed lines"
            if request.file.change == .untracked {
                Text("\(lines) in “\(request.file.path)” are taken out of it. The file is not tracked, so git has no copy of them.")
            } else {
                Text("\(lines) in “\(request.file.path)” go back to the staged version. The unstaged changes to them are lost.")
            }
        }
        .alert(
            "Stash the Selected Lines?",
            isPresented: Binding { pendingStash != nil } set: { if !$0 { pendingStash = nil } },
            presenting: pendingStash
        ) { request in
            TextField("Message", text: $stashMessage, prompt: Text("Optional"))
            Button("Cancel", role: .cancel) {}
            Button("Stash") {
                let message = stashMessage
                Task { await model.saveStash(lines: request.lines, of: request.file, message: message) }
            }
        } message: { request in
            Text("The lines are set aside in a new stash and taken out of “\(request.file.path)”. The rest of its changes stay.")
        }
    }

    /// Stage or unstage controls, and on the unstaged side discard, for a
    /// file whose lines can be told apart.
    private func actions(for file: FileDiff, side: WorkingCopySide) -> DiffLineActions? {
        // A diff that hides whitespace changes cannot say exactly what to stage.
        guard !file.isBinary, file.change != .conflicted, DiffPreferences.shared.options.isExact else { return nil }
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
            } stash: { lines in
                stashMessage = ""
                pendingStash = LineStash(file: file, lines: lines)
            }
        }
    }

    private func load() async {
        guard let path = model.workingCopy.selection else {
            loaded = nil
            return
        }
        do {
            let options = DiffPreferences.shared.options
            let staged = try await model.repository.stagedDiff(of: path, options: options)
            let unstaged = try await model.repository.unstagedDiff(of: path, options: options)
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
