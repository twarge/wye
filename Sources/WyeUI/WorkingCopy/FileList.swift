import Foundation
import GitKit

/// The order of the changed files within a folder.
enum FileListSort: String, CaseIterable, Identifiable {
    /// By the file's name.
    case name
    /// By how the file changed, then by name.
    case status

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .status: "Status"
        }
    }
}

/// A folder or a file in the tree of changed files.
struct FileTreeNode: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A folder, with the files somewhere under it.
        case folder(entries: [StatusEntry])
        case file(StatusEntry)
    }

    /// The folder's or the file's path. A folder's ends in `/`, so it never
    /// clashes with a file's.
    var id: String
    /// What the row shows: a file's name, or a folder's, or for a chain of
    /// folders that hold nothing but each other, all their names.
    var name: String
    var kind: Kind
    var children: [FileTreeNode]

    /// The folder's path without its final `/`, or the file's path.
    var path: String {
        id.hasSuffix("/") ? String(id.dropLast()) : id
    }

    var entries: [StatusEntry] {
        switch kind {
        case .folder(let entries): entries
        case .file(let entry): [entry]
        }
    }

    var isFolder: Bool {
        if case .folder = kind { true } else { false }
    }
}

/// What the working copy's list tells its rows apart by, and selects by.
///
/// A file whose changes are all staged or all unstaged has one row, which
/// is the same row once they are staged or unstaged: the list then moves it
/// from one section to the other, still selected, instead of taking one row
/// out and putting another in. A file with changes on both sides has a row
/// in each section. Folders go the same way.
enum ChangeRowID: Hashable {
    /// A file's or a folder's row: under Unstaged while anything of it is
    /// unstaged, otherwise under Staged.
    case item(String)
    /// The row under Staged of a file or a folder that has unstaged changes too.
    case stagedPart(String)

    /// The file's or the folder's path, a folder's ending in `/`.
    var path: String {
        switch self {
        case .item(let path), .stagedPart(let path): path
        }
    }

    /// The path of the file, when the row is a file's.
    var filePath: String? {
        path.hasSuffix("/") ? nil : path
    }
}

/// A node of a section's tree as a row, once collapsed folders are left out.
struct ChangeRow: Identifiable, Hashable {
    var id: ChangeRowID
    /// The section the row is in.
    var side: WorkingCopySide
    var node: FileTreeNode
    /// How many folders deep the row is.
    var depth: Int
}

/// The rows of the working copy's two sections of changes.
struct ChangeSections: Hashable {
    var staged: [ChangeRow] = []
    var unstaged: [ChangeRow] = []

    var isEmpty: Bool { staged.isEmpty && unstaged.isEmpty }

    subscript(side: WorkingCopySide) -> [ChangeRow] {
        side == .staged ? staged : unstaged
    }
}

/// What the Stage button does with the selected rows.
struct StagingAction: Hashable {
    /// The section the files are taken from: staging takes them from Unstaged.
    var from: WorkingCopySide
    var paths: [String]
}

extension ChangeSections {
    /// How many files a section lists, those in collapsed folders too.
    func fileCount(on side: WorkingCopySide) -> Int {
        self[side].reduce(0) { $1.depth == 0 ? $0 + $1.node.entries.count : $0 }
    }

    /// The files of the selected rows of one section, each once, in the
    /// list's order. A folder's row stands for every file under it there.
    func paths(of selection: Set<ChangeRowID>, on side: WorkingCopySide) -> [String] {
        var seen: Set<String> = []
        return self[side].lazy
            .filter { selection.contains($0.id) }
            .flatMap(\.node.entries)
            .map(\.path)
            .filter { seen.insert($0).inserted }
    }
}

/// The selected rows and the files they stand for in each section, worked
/// out once for the Stage button and for every row's menu.
struct SelectedChanges {
    var rows: Set<ChangeRowID>
    var staged: [String]
    var unstaged: [String]

    init(_ rows: Set<ChangeRowID>, in sections: ChangeSections) {
        self.rows = rows
        staged = sections.paths(of: rows, on: .staged)
        unstaged = sections.paths(of: rows, on: .unstaged)
    }

    /// What the Stage button does: it stages the selected rows under
    /// Unstaged, and with none selected there, unstages those under Staged.
    var action: StagingAction? {
        if !unstaged.isEmpty { return StagingAction(from: .unstaged, paths: unstaged) }
        if !staged.isEmpty { return StagingAction(from: .staged, paths: staged) }
        return nil
    }

    /// Whether the row is one of several selected, which its menu then
    /// acts on together.
    func includes(_ row: ChangeRow) -> Bool {
        rows.count > 1 && rows.contains(row.id)
    }

    /// What a row's own Stage or Unstage acts on: the selected rows of its
    /// section when it is one of several selected, otherwise the row.
    func paths(for row: ChangeRow) -> [String] {
        guard includes(row) else { return row.node.entries.map(\.path) }
        return row.side == .staged ? staged : unstaged
    }
}

extension StatusEntry {
    /// How the file changed on one side: what its row in that section shows.
    func change(on side: WorkingCopySide) -> FileChange {
        (side == .staged ? staged : unstaged) ?? change
    }
}

/// Filtering, sorting and folding the working copy's changed files: the
/// logic behind its list, kept apart from the view so it can be tested.
enum FileList {
    /// The entries whose path holds every word of `query`, ignoring case
    /// and accents. An empty query keeps everything.
    static func filtered(_ entries: [StatusEntry], by query: String) -> [StatusEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            words.allSatisfy { word in
                entry.path.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || entry.originalPath?.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Files in the order one folder of a section lists them.
    static func sorted(_ entries: [StatusEntry], by sort: FileListSort, side: WorkingCopySide) -> [StatusEntry] {
        entries.sorted { lhs, rhs in
            switch sort {
            case .name:
                let left = lhs.path.splitPath.name, right = rhs.path.splitPath.name
                if left != right { return compare(left, right) }
            case .status:
                let left = rank(lhs.change(on: side)), right = rank(rhs.change(on: side))
                if left != right { return left < right }
            }
            return compare(lhs.path, rhs.path)
        }
    }

    /// The changes as the rows of the list's two sections: under Staged
    /// every file with staged changes, under Unstaged every file with
    /// unstaged ones, each as a tree. A file with both is in both.
    ///
    /// - Parameters:
    ///   - entries: Every change that is not a conflict.
    ///   - query: What the filter holds; see `filtered(_:by:)`.
    ///   - collapsed: The rows of the folders that are folded.
    static func sections(
        _ entries: [StatusEntry], matching query: String = "", sort: FileListSort, collapsed: Set<ChangeRowID> = []
    ) -> ChangeSections {
        // Whatever the filter leaves out, so that a row stays the same row
        // while the filter is typed.
        let alsoUnstaged = pathsWithUnstagedChanges(entries)
        let shown = filtered(entries, by: query)
        func rows(_ side: WorkingCopySide) -> [ChangeRow] {
            let nodes = tree(shown.filter { (side == .staged ? $0.staged : $0.unstaged) != nil }, sort: sort, side: side)
            var rows: [ChangeRow] = []
            append(nodes, side: side, depth: 0, to: &rows, collapsed: collapsed) { node in
                side == .staged && alsoUnstaged.contains(node.id[...]) ? .stagedPart(node.id) : .item(node.id)
            }
            return rows
        }
        return ChangeSections(staged: rows(.staged), unstaged: rows(.unstaged))
    }

    /// The entries on one side as a tree of folders, folders before files
    /// at each level. Folders go by name; files by `sort`.
    static func tree(_ entries: [StatusEntry], sort: FileListSort, side: WorkingCopySide) -> [FileTreeNode] {
        let built = Folder()
        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            var folder = built
            for name in components.dropLast() {
                if let existing = folder.folders[name] {
                    folder = existing
                } else {
                    let child = Folder()
                    folder.folders[name] = child
                    folder = child
                }
            }
            folder.files.append(entry)
        }
        return nodes(in: built, prefix: "", sort: sort, side: side)
    }

    // MARK: Building

    /// A folder while the tree is being built.
    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [StatusEntry] = []

        var allEntries: [StatusEntry] {
            files + folders.values.flatMap(\.allEntries)
        }
    }

    private static func nodes(
        in folder: Folder, prefix: String, sort: FileListSort, side: WorkingCopySide
    ) -> [FileTreeNode] {
        let folders = folder.folders.sorted { lhs, rhs in
            lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }.map { name, child -> FileTreeNode in
            // A folder that holds only one folder is shown together with it.
            var name = name
            var child = child
            var path = prefix + name
            while child.files.isEmpty, child.folders.count == 1, let (innerName, inner) = child.folders.first {
                name += "/" + innerName
                path += "/" + innerName
                child = inner
            }
            let entries = child.allEntries.sorted { compare($0.path, $1.path) }
            return FileTreeNode(
                id: path + "/", name: name, kind: .folder(entries: entries),
                children: nodes(in: child, prefix: path + "/", sort: sort, side: side)
            )
        }
        let files = sorted(folder.files, by: sort, side: side).map { entry in
            FileTreeNode(id: entry.path, name: entry.path.splitPath.name, kind: .file(entry), children: [])
        }
        return folders + files
    }

    /// Adds the nodes as rows, leaving out what a collapsed folder holds.
    private static func append(
        _ nodes: [FileTreeNode], side: WorkingCopySide, depth: Int, to rows: inout [ChangeRow],
        collapsed: Set<ChangeRowID>, id: (FileTreeNode) -> ChangeRowID
    ) {
        for node in nodes {
            let row = ChangeRow(id: id(node), side: side, node: node, depth: depth)
            rows.append(row)
            if node.isFolder, !collapsed.contains(row.id) {
                append(node.children, side: side, depth: depth + 1, to: &rows, collapsed: collapsed, id: id)
            }
        }
    }

    /// The path of every file with unstaged changes, and of every folder
    /// one of them is in, as a tree's nodes are named.
    private static func pathsWithUnstagedChanges(_ entries: [StatusEntry]) -> Set<Substring> {
        var paths: Set<Substring> = []
        // Only a staged row is ever looked up.
        guard entries.contains(where: { $0.staged != nil }) else { return paths }
        for entry in entries where entry.unstaged != nil {
            let path = entry.path[...]
            paths.insert(path)
            for index in path.indices where path[index] == "/" {
                paths.insert(path[...index])
            }
        }
        return paths
    }

    // MARK: Ordering

    /// Paths in the order a person expects: case aside, with numbers by value.
    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs < rhs
        }
    }

    /// Where a file goes when sorting by status.
    static func rank(_ change: FileChange) -> Int {
        switch change {
        case .conflicted: 0
        case .added: 1
        case .modified: 2
        case .renamed: 3
        case .copied: 4
        case .typeChanged: 5
        case .deleted: 6
        case .untracked: 7
        }
    }
}
