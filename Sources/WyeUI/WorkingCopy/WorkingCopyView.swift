import GitKit
import SwiftUI
import TipKit

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
    /// Folders of the trees the user folded, by their rows.
    @State private var collapsedFolders: Set<ChangeRowID> = []
    /// The files left out of the list unless asked for, read on refresh.
    @State private var hidden = HiddenFiles()

    @AppStorage("workingCopy.sort") private var sort = FileListSort.name
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
        let changes = model.workingCopy.entries.filter { !$0.isConflicted }
        let sections = FileList.sections(
            changes, matching: filter, sort: sort, collapsed: isFiltering ? [] : collapsedFolders
        )
        let selected = SelectedChanges(model.workingCopy.listSelection, in: sections)
        let ignored = showsIgnored ? filteredPaths(hidden.ignored) : []
        let assumed = showsAssumeUnchanged ? filteredPaths(hidden.assumeUnchanged) : []
        List(selection: $model.workingCopy.listSelection) {
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
                        .tag(ChangeRowID.item(entry.path))
                    }
                }
            }
            // What the commit takes first, under the commit. Both show
            // while there are changes, so that there is always somewhere
            // for a file to go; a filter shows only what it finds.
            changeSection(.staged, in: sections, selected: selected, showsEmpty: !changes.isEmpty && !isFiltering)
            changeSection(.unstaged, in: sections, selected: selected, showsEmpty: !changes.isEmpty && !isFiltering)
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
        .listStyle(.plain)
        // A file staged or unstaged moves from one section to the other.
        .animation(Platform.reducesMotion ? nil : .snappy, value: model.workingCopy.entries)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            // As in any outline: left folds the selected folders, right opens them.
            let folders = model.workingCopy.listSelection.filter { $0.filePath == nil }
            guard !folders.isEmpty else { return .ignored }
            if press.key == .leftArrow {
                collapsedFolders.formUnion(folders)
            } else {
                collapsedFolders.subtract(folders)
            }
            return .handled
        }
        .quickLookOnSpace(in: model.repository) {
            // The files on disk; one deleted there, as the index has it.
            model.workingCopy.selectedPaths.sorted().map { path in
                PreviewItem(path: path, source: model.fileExists(path) ? .workingTree : .index)
            }
        }
        // The window follows changes on disk; iOS sees only some of them.
        .refreshable { await model.refresh() }
        .workingCopyDrops(model)
        .overlay {
            if model.workingCopy.entries.isEmpty && ignored.isEmpty && assumed.isEmpty {
                ContentUnavailableView(
                    "No Local Changes",
                    systemImage: "checkmark.circle",
                    description: Text("The working copy matches the last commit.")
                )
            } else if conflicted.isEmpty && sections.isEmpty && ignored.isEmpty && assumed.isEmpty {
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
                FileListControls(filter: $filter, sort: $sort, staging: selected.action, perform: perform)
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
            }
            if Platform.selectsSeveralInEditMode {
                // Tapping a file shows it; this is how to select files to stage.
                ToolbarItem(placement: .primaryAction) {
                    SelectionModeButton()
                }
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

    /// Whether the filter leaves files out: then no folder is folded, and
    /// a section with nothing found is left out.
    private var isFiltering: Bool {
        !filter.allSatisfy(\.isWhitespace)
    }

    /// The staged or the unstaged changes: the files under their folders.
    @ViewBuilder
    private func changeSection(
        _ side: WorkingCopySide, in sections: ChangeSections, selected: SelectedChanges, showsEmpty: Bool
    ) -> some View {
        let rows = sections[side]
        if !rows.isEmpty || showsEmpty {
            Section {
                if rows.isEmpty {
                    Text(side == .staged ? "No staged changes" : "No unstaged changes")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .selectionDisabled()
                } else {
                    ForEach(rows) { row in
                        switch row.node.kind {
                        case .folder:
                            folderRow(row, selected: selected)
                        case .file(let entry):
                            fileRow(entry, row, selected: selected)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(side == .staged ? "Staged" : "Unstaged")
                    Spacer()
                    if !rows.isEmpty {
                        Text(sections.fileCount(on: side).formatted())
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func folderRow(_ row: ChangeRow, selected: SelectedChanges) -> some View {
        let symbol = row.side == .staged ? "minus.square" : "plus.square"
        return FolderRow(node: row.node, depth: row.depth, isCollapsed: !isFiltering && collapsedFolders.contains(row.id)) {
            if collapsedFolders.contains(row.id) {
                collapsedFolders.remove(row.id)
            } else {
                collapsedFolders.insert(row.id)
            }
        }
        .selectionDisabled(!Platform.selectsFolders)
        .fileDrag(model.fileExists(row.node.path)
                  ? FileDrag(repository: model.repository, path: row.node.path, isFolder: true) : nil)
        .accessibilityAction(named: row.side == .staged ? "Unstage Folder" : "Stage Folder") {
            perform(StagingAction(from: row.side, paths: row.node.entries.map(\.path)))
        }
        .contextMenu {
            Button(stagingTitle(for: row, selected: selected), systemImage: symbol) {
                perform(StagingAction(from: row.side, paths: selected.paths(for: row)))
            }
            Section {
                // The folder as a whole, whichever section its row is in.
                Button("Stash Folder…", systemImage: "archivebox") {
                    stashingFiles = StashFiles(paths: changedPaths(in: row.node))
                }
                Button("Save Folder as Patch…", systemImage: "doc.badge.arrow.up") {
                    Task { await model.savePatch(.files(changedPaths(in: row.node))) }
                }
            }
            WorkingCopyFolderMenu(model: model, node: row.node)
        }
        .swipeActions(edge: .leading) {
            Button(row.side == .staged ? "Unstage" : "Stage", systemImage: symbol) {
                perform(StagingAction(from: row.side, paths: row.node.entries.map(\.path)))
            }
            .tint(.accentColor)
        }
    }

    private func fileRow(_ entry: StatusEntry, _ row: ChangeRow, selected: SelectedChanges) -> some View {
        let verb = row.side == .staged ? "Unstage" : "Stage"
        let symbol = row.side == .staged ? "minus.square" : "plus.square"
        return FileLabel(entry: entry, change: entry.change(on: row.side), showsFolder: false)
            .padding(.vertical, 2)
            // Past where a folder has its chevron, so files line up with folders.
            .padding(.leading, CGFloat(row.depth) * FolderRow.indent + FolderRow.chevronWidth)
            .fileDrag(model.fileExists(entry.path) ? FileDrag(repository: model.repository, path: entry.path) : nil)
            .accessibilityAction(named: verb) { perform(StagingAction(from: row.side, paths: [entry.path])) }
            .contextMenu {
                Button(stagingTitle(for: row, selected: selected), systemImage: symbol) {
                    perform(StagingAction(from: row.side, paths: selected.paths(for: row)))
                }
                if row.side == .unstaged {
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
                Button(verb, systemImage: symbol) {
                    perform(StagingAction(from: row.side, paths: [entry.path]))
                }
                .tint(.accentColor)
            }
            .swipeActions(edge: .trailing) {
                if row.side == .unstaged {
                    // Not destructive in role: that would take the row away
                    // before the discard is confirmed.
                    Button("Discard", systemImage: "trash") {
                        pendingDiscard = .file(entry.path, isUntracked: entry.unstaged == .untracked)
                    }
                    .tint(.red)
                }
            }
    }

    /// What a row's menu calls staging or unstaging: the row alone, or
    /// with the rows selected with it, their files.
    private func stagingTitle(for row: ChangeRow, selected: SelectedChanges) -> String {
        let verb = row.side == .staged ? "Unstage" : "Stage"
        if selected.includes(row) {
            return "\(verb) \(selected.paths(for: row).count.formatted()) Files"
        }
        return row.node.isFolder ? "\(verb) Folder" : verb
    }

    /// Every changed file in a folder, staged or not.
    private func changedPaths(in folder: FileTreeNode) -> [String] {
        model.workingCopy.entries.filter { $0.path.hasPrefix(folder.id) && !$0.isConflicted }.map(\.path)
    }

    /// Stages what the action takes from Unstaged, or unstages what it
    /// takes from Staged.
    private func perform(_ action: StagingAction) {
        Task {
            switch action.from {
            case .unstaged: await model.stage(action.paths)
            case .staged: await model.unstage(action.paths)
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
            model.report(error)
        }
        guard !Task.isCancelled else { return }
        hidden = files
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

/// A folder of a tree of changed files, which folds. Where folders are
/// selected, the chevron folds it and the rest of the row selects it;
/// elsewhere the whole row folds it.
private struct FolderRow: View {
    static let indent: CGFloat = 16
    /// The room the chevron takes, which a file's row leaves empty.
    static let chevronWidth: CGFloat = 16

    var node: FileTreeNode
    var depth: Int
    var isCollapsed: Bool
    var toggleCollapsed: () -> Void

    var body: some View {
        Group {
            if Platform.selectsFolders {
                HStack(spacing: 0) {
                    Button(action: toggleCollapsed) {
                        chevron
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCollapsed ? "Expand" : "Collapse")
                    label
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                }
            } else {
                Button(action: toggleCollapsed) {
                    HStack(spacing: 0) {
                        chevron
                        label
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(node.name)
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                .accessibilityHint(isCollapsed ? "Shows the files in this folder" : "Hides the files in this folder")
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(depth) * Self.indent)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(isCollapsed ? .zero : .degrees(90))
            .frame(width: Self.chevronWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
    }

    private var label: some View {
        HStack(spacing: 6) {
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

/// The filter, the button that stages or unstages the selected files, and
/// the order of the files.
private struct FileListControls: View {
    @Binding var filter: String
    @Binding var sort: FileListSort
    /// What the button does with the selected rows, if they can be staged
    /// or unstaged.
    var staging: StagingAction?
    var perform: (StagingAction) -> Void

    var body: some View {
        let unstages = staging?.from == .staged
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

            Button {
                if let staging { perform(staging) }
            } label: {
                // As wide as the longer of its titles, so that the filter
                // keeps its width when the selection changes sides.
                Text("Unstage")
                    .hidden()
                    .overlay { Text(unstages ? "Unstage" : "Stage") }
            }
            .buttonStyle(.bordered)
            .disabled(staging == nil)
            .accessibilityLabel(unstages ? "Unstage" : "Stage")
            .help(unstages ? "Unstage the selected files" : "Stage the selected files")

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
    /// The change the badge shows: in a section, the one on its side.
    var change: FileChange?
    var showsFolder = true

    var body: some View {
        let path = entry.path.splitPath
        HStack(spacing: 8) {
            FileChangeBadge(change: change ?? entry.change)
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
                        if DiffPreferences.shared.options.isExact, loaded.unstaged != nil {
                            TipView(StageLinesTip())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
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
                            .diffPackages([staged])
                        }
                        if let unstaged = loaded.unstaged {
                            FileDiffView(
                                file: unstaged, caption: "Unstaged", isCollapsed: isCollapsed("unstaged"),
                                actions: actions(for: unstaged, side: .unstaged)
                            )
                            .diffPackages([unstaged])
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
            model.report(error)
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
