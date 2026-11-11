import GitKit
import SwiftUI

/// What the working copy lets you do to a diff's hunks and lines. A commit's
/// diff is read-only and has none.
struct DiffLineActions {
    /// What the main control does: "Stage" or "Unstage".
    var verb: String
    var systemImage: String
    /// The selected lines, by ID: the added and removed lines a control acts on.
    var selection: Binding<Set<Int>>
    /// Stages or unstages lines, given by their IDs.
    var apply: (Set<Int>) -> Void
    /// Throws lines away, given by their IDs; `nil` where that is not offered.
    /// The caller confirms first.
    var discard: ((Set<Int>) -> Void)?
    /// Stashes lines, given by their IDs; `nil` where that is not offered.
    var stash: ((Set<Int>) -> Void)? = nil
}

/// One file's diff: a header that folds it, then its lines.
///
/// Its body is several views in a row rather than one stack, so that inside a
/// lazy stack each line is made only when it scrolls into view.
struct FileDiffView: View {
    var file: FileDiff
    /// Shown before the path, such as "Staged".
    var caption: String?
    @Binding var isCollapsed: Bool
    /// Controls for staging and discarding hunks and lines, when the diff can
    /// be changed.
    var actions: DiffLineActions?
    /// Ways to open the file elsewhere (its history, blame), offered as the
    /// header's context menu.
    var fileActions: FileActions?

    /// Where a range selection starts: the line selected last.
    @State private var anchor: Int?
    /// Syntax colours and changes within lines, worked out off the main actor.
    @State private var decorations = DiffDecorationLoader()
    @Environment(FindModel.self) private var find: FindModel?

    var body: some View {
        header
        if !isCollapsed {
            if let submodule = file.submodule {
                SubmoduleDiffRows(change: submodule)
            } else if file.isBinary {
                if ImageDiffView.canShow(file) {
                    ImageDiffView(file: file)
                } else {
                    note("Binary file")
                }
            } else if file.hunks.isEmpty {
                note(file.change == .renamed ? "Renamed without changes" : "No changes to show")
            } else {
                let gutter = file.gutterWidth(digit: AppearancePreferences.shared.digitWidth)
                let style = DiffTextStyle(
                    tabWidth: DiffPreferences.shared.tabWidth, showsInvisibles: DiffPreferences.shared.showsInvisibles
                )
                let decorated = decorations.decorations
                let findGroup = FindRow.group(for: file, caption: caption)
                ForEach(file.hunks) { hunk in
                    hunkHeader(hunk)
                        .diffLineMenu(actions, lines: menuLines(for: hunk), isHunk: menuLines(for: hunk) == hunk.changedLineIDs)
                    ForEach(hunk.lines) { line in
                        DiffLineView(
                            line: line,
                            gutter: gutter,
                            style: style,
                            isSelected: isSelected(line),
                            toggle: actions != nil && line.isChange ? { toggle(line) } : nil,
                            tokens: decorated?.tokens[line.id] ?? [],
                            changes: decorated?.changes[line.id] ?? [],
                            findRow: FindRow(group: findGroup, line: line.id)
                        )
                        .onAppear { decorations.load(file) }
                        .diffLineMenu(actions, lines: menuLines(for: line))
                        // Outermost, so find can scroll to rows not yet made.
                        .id(FindRow(group: findGroup, line: line.id))
                    }
                }
                if file.isTruncated {
                    note("The rest of this diff is too long to show")
                }
            }
        }
    }

    private var header: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(isCollapsed ? .zero : .degrees(90))
                FileChangeBadge(change: file.change)
                if let caption {
                    Text(caption)
                        .foregroundStyle(.secondary)
                }
                Text(file.change == .renamed ? "\(file.oldPath) → \(file.path)" : file.path)
                    .font(.code)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .foregroundStyle(.green)
                }
                if file.deletions > 0 {
                    Text("−\(file.deletions)")
                        .foregroundStyle(.red)
                }
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fileActionsMenu(fileActions)
        .background(.fill.tertiary)
        .padding(.top, 10)
        .onAppear { decorations.load(file) }
        .onChange(of: file) { decorations.load(file) }
        // Find unfolds a folded file to show a match in it.
        .onChange(of: find?.currentMatch) {
            if isCollapsed, find?.currentMatch?.row.group == FindRow.group(for: file, caption: caption) {
                isCollapsed = false
            }
        }
    }

    private func hunkHeader(_ hunk: FileDiff.Hunk) -> some View {
        HStack(spacing: 12) {
            Text(hunk.header)
                .font(AppearancePreferences.shared.smallCodeFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let actions {
                HunkControls(hunk: hunk, actions: actions)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isSelected(_ line: FileDiff.Line) -> Bool {
        actions?.selection.wrappedValue.contains(line.id) ?? false
    }

    /// Adds a line to the selection or takes it out; with a shift-click,
    /// adds every changed line from the last one selected to this one.
    private func toggle(_ line: FileDiff.Line) {
        guard let selection = actions?.selection else { return }
        if Platform.isExtendingSelection, let anchor, anchor != line.id {
            let range = min(anchor, line.id)...max(anchor, line.id)
            let lines = file.hunks.lazy.flatMap(\.lines).filter { $0.isChange && range.contains($0.id) }
            selection.wrappedValue.formUnion(lines.map(\.id))
        } else if selection.wrappedValue.contains(line.id) {
            selection.wrappedValue.remove(line.id)
        } else {
            selection.wrappedValue.insert(line.id)
        }
        anchor = line.id
    }
}

/// A hunk's Stage or Unstage and Discard buttons. They act on the hunk's
/// selected lines when it has any, otherwise on the whole hunk.
private struct HunkControls: View {
    var hunk: FileDiff.Hunk
    var actions: DiffLineActions

    var body: some View {
        let selected = actions.selection.wrappedValue.intersection(hunk.changedLineIDs)
        let target = selected.isEmpty ? hunk.changedLineIDs : selected
        let noun = switch selected.count {
        case 0: "Hunk"
        case 1: "Line"
        default: "\(selected.count) Lines"
        }
        HStack(spacing: 12) {
            if !selected.isEmpty {
                Button("Deselect", systemImage: "xmark") {
                    actions.selection.wrappedValue.subtract(selected)
                }
                .labelStyle(.iconOnly)
                .help("Deselect this hunk’s lines")
            }
            if let discard = actions.discard {
                Button("Discard \(noun)", systemImage: "trash") {
                    discard(target)
                }
                .help(selected.isEmpty ? "Throw away this hunk’s changes" : "Throw away the selected lines’ changes")
            }
            Button("\(actions.verb) \(noun)", systemImage: actions.systemImage) {
                actions.apply(target)
            }
            .help(selected.isEmpty ? "\(actions.verb) this hunk" : "\(actions.verb) the selected lines")
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

private struct DiffLineView: View {
    var line: FileDiff.Line
    var gutter: CGFloat
    var style: DiffTextStyle
    var isSelected: Bool
    /// Selects or deselects the line, for a line that can be staged on its own.
    var toggle: (() -> Void)?
    var tokens: [SyntaxToken] = []
    /// The part of the line that differs from the line it replaced or was replaced by.
    var changes: [LineMark] = []
    /// The line's ID for find, which is also its scroll ID.
    var findRow: FindRow

    @Environment(FindModel.self) private var find: FindModel?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let toggle {
            row
                .contentShape(.rect)
                .onTapGesture(perform: toggle)
                .overlay(alignment: .leading) {
                    if isSelected {
                        Rectangle()
                            .fill(.tint)
                            .frame(width: 3)
                    }
                }
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint("Selects the line for staging on its own")
                .help("Click to select the line; shift-click to select up to it")
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
        }
        .font(AppearancePreferences.shared.codeFont)
        .padding(.vertical, 1)
        .background(background)
    }

    /// The line's text in its syntax colours, with tabs laid out and, when
    /// asked for, spaces and tabs drawn faintly as dots and arrows; the
    /// changed part of the line and any find matches marked behind it.
    private var content: Text {
        guard line.kind != .noNewline, !line.text.isEmpty else { return Text(line.text.isEmpty ? " " : line.text) }
        let renderer = CodeLineRenderer(
            tabWidth: style.tabWidth,
            showsInvisibles: style.showsInvisibles,
            theme: AppearancePreferences.shared.theme,
            scheme: colorScheme,
            changeColor: line.kind == .addition ? DiffColors.addedChange : DiffColors.removedChange
        )
        let matches = find?.marks(for: findRow) ?? []
        return Text(renderer.render(line.text, tokens: tokens, marks: changes + matches))
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: gutter, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context, .noNewline: ""
        }
    }

    private var background: Color {
        if isSelected {
            return .accentColor.opacity(0.3)
        }
        return switch line.kind {
        case .addition: DiffColors.added
        case .deletion: DiffColors.removed
        case .context, .noNewline: .clear
        }
    }
}

private extension FileDiff {
    /// Room for the longest line number in the file, `digit` wide a digit.
    func gutterWidth(digit: CGFloat) -> CGFloat {
        // Numbers only grow, so the largest are in the last hunk.
        let largest = hunks.last?.lines.reduce(0) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) } ?? 0
        return CGFloat(String(max(largest, 10)).count) * digit + 6
    }
}

/// The backgrounds of added and removed lines, and the stronger ones for
/// the part of a line that changed, chosen to keep every syntax theme's
/// text readable in light and dark.
enum DiffColors {
    static let added = Color.green.opacity(0.16)
    static let removed = Color.red.opacity(0.16)
    static let addedChange = Color.green.opacity(0.34)
    static let removedChange = Color.red.opacity(0.34)
}

/// A submodule's change: the commits it records on each side and, when the
/// submodule is here to read, the commits between them, as
/// `git diff --submodule=log` lists them. Rows in a row, like the lines of
/// a file's diff, so a lazy stack makes each only when it shows.
private struct SubmoduleDiffRows: View {
    var change: SubmoduleChange

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            Text(range)
                .font(.code)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.fill.quaternary)
        if let changes = change.changes.subtracting(.newCommits).summary {
            note("The submodule has \(changes), which are not part of this change: commit them inside it first.")
        }
        ForEach(change.commits) { commit in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(commit.isAdded ? "+" : "−")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(commit.id.abbreviated())
                    .foregroundStyle(.secondary)
                Text(commit.summary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.code)
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
            .background(commit.isAdded ? Color.green.opacity(0.16) : Color.red.opacity(0.16))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(commit.isAdded ? "Adds" : "Takes away") \(commit.summary)")
        }
        if change.isTruncated {
            note("Only the first \(SubmoduleChange.commitLimit) commits each way are shown")
        }
        if let explanation {
            note(explanation)
        }
    }

    private var range: String {
        switch (change.oldID, change.newID) {
        case (nil, let new?): "Submodule added at \(new.abbreviated())"
        case (let old?, nil): "Submodule removed, was at \(old.abbreviated())"
        case (let old?, let new?) where old == new: "Submodule at \(new.abbreviated())"
        case (let old?, let new?): "Submodule \(old.abbreviated()) → \(new.abbreviated())"
        case (nil, nil): "Submodule"
        }
    }

    private var explanation: String? {
        guard change.oldID != change.newID, change.oldID != nil, change.newID != nil else { return nil }
        if !change.isAvailable {
            return "The commits in between can’t be listed: the submodule isn’t cloned here, or lacks one of these commits. Update or fetch it to see them."
        }
        return change.commits.isEmpty ? "No commits between them" : nil
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
