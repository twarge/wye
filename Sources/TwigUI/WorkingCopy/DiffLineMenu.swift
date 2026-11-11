import GitKit
import SwiftUI

extension View {
    /// A context menu (a long press on iOS) that stages or unstages,
    /// discards or stashes `lines` of a working copy diff. Nothing for a
    /// diff that cannot be changed, or for a line that is not a change.
    func diffLineMenu(_ actions: DiffLineActions?, lines: Set<Int>, isHunk: Bool = false) -> some View {
        modifier(DiffLineMenu(actions: actions, lines: lines, isHunk: isHunk))
    }
}

extension FileDiffView {
    /// What a line's menu acts on: the selection when the line is in it,
    /// otherwise the line alone.
    func menuLines(for line: FileDiff.Line) -> Set<Int> {
        guard let actions, line.isChange else { return [] }
        let selection = actions.selection.wrappedValue
        return selection.contains(line.id) ? selection : [line.id]
    }

    /// What a hunk header's menu acts on: the hunk's selected lines, or all
    /// of its changes, as its buttons do.
    func menuLines(for hunk: FileDiff.Hunk) -> Set<Int> {
        guard let actions else { return [] }
        let selected = actions.selection.wrappedValue.intersection(hunk.changedLineIDs)
        return selected.isEmpty ? hunk.changedLineIDs : selected
    }
}

private struct DiffLineMenu: ViewModifier {
    var actions: DiffLineActions?
    var lines: Set<Int>
    var isHunk: Bool

    func body(content: Content) -> some View {
        if let actions, !lines.isEmpty {
            content.contextMenu {
                let noun = isHunk ? "Hunk" : lines.count == 1 ? "Line" : "\(lines.count.formatted()) Lines"
                Button("\(actions.verb) \(noun)", systemImage: actions.systemImage) {
                    actions.apply(lines)
                }
                if let stash = actions.stash {
                    Button("Stash \(noun)…", systemImage: "archivebox") { stash(lines) }
                }
                if let discard = actions.discard {
                    Divider()
                    Button("Discard \(noun)…", systemImage: "trash", role: .destructive) { discard(lines) }
                }
            }
        } else {
            content
        }
    }
}
