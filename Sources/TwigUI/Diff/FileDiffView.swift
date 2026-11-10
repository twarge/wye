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

    var body: some View {
        header
        if !isCollapsed {
            if file.isBinary {
                note("Binary file")
            } else if file.hunks.isEmpty {
                note(file.change == .renamed ? "Renamed without changes" : "No changes to show")
            } else {
                let gutter = file.gutterWidth
                let style = DiffTextStyle(
                    tabWidth: DiffPreferences.shared.tabWidth, showsInvisibles: DiffPreferences.shared.showsInvisibles
                )
                ForEach(file.hunks) { hunk in
                    hunkHeader(hunk)
                    ForEach(hunk.lines) { line in
                        DiffLineView(
                            line: line,
                            gutter: gutter,
                            style: style,
                            isSelected: isSelected(line),
                            toggle: actions != nil && line.isChange ? { toggle(line) } : nil
                        )
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
    }

    private func hunkHeader(_ hunk: FileDiff.Hunk) -> some View {
        HStack(spacing: 12) {
            Text(hunk.header)
                .font(.smallCode)
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
        .font(.code)
        .padding(.vertical, 1)
        .background(background)
    }

    /// The line's text, with tabs laid out and, when asked for, spaces and
    /// tabs drawn faintly as dots and arrows.
    private var content: Text {
        guard line.kind != .noNewline, !line.text.isEmpty else { return Text(line.text.isEmpty ? " " : line.text) }
        let runs = style.runs(line.text)
        guard runs.count > 1 || runs.first?.isInvisible == true else { return Text(runs.first?.text ?? line.text) }
        var text = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.isInvisible {
                piece.foregroundColor = .secondary.opacity(0.6)
            }
            text += piece
        }
        return Text(text)
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
        case .addition: .green.opacity(0.16)
        case .deletion: .red.opacity(0.16)
        case .context, .noNewline: .clear
        }
    }
}

private extension FileDiff {
    /// Room for the longest line number in the file.
    var gutterWidth: CGFloat {
        // Numbers only grow, so the largest are in the last hunk.
        let largest = hunks.last?.lines.reduce(0) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) } ?? 0
        return CGFloat(String(max(largest, 10)).count) * 8 + 6
    }
}
