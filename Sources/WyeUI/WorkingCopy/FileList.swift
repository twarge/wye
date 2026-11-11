import Foundation
import GitKit

/// How the working copy lists its changed files.
enum FileListLayout: String, CaseIterable, Identifiable {
    /// One row per file, its folder under its name.
    case list
    /// Files under collapsible folders.
    case tree

    var id: Self { self }

    var title: String {
        switch self {
        case .list: "List"
        case .tree: "Tree"
        }
    }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .tree: "list.bullet.indent"
        }
    }
}

/// The order of the changed files.
enum FileListSort: String, CaseIterable, Identifiable {
    /// By the whole path, so files stay with their folders.
    case path
    /// By the file's own name, wherever it is.
    case name
    /// Conflicts first, then by how the file changed, then by path.
    case status

    var id: Self { self }

    var title: String {
        switch self {
        case .path: "Path"
        case .name: "Name"
        case .status: "Status"
        }
    }
}

/// Whether a file or a folder of files is staged.
enum StagingState: Hashable {
    case unstaged
    case partlyStaged
    case staged

    init(_ entries: some Sequence<StatusEntry>) {
        var anyStaged = false, anyUnstaged = false
        for entry in entries {
            if entry.staged != nil { anyStaged = true }
            if entry.unstaged != nil { anyUnstaged = true }
            if entry.staged != nil && entry.unstaged != nil {
                self = .partlyStaged
                return
            }
        }
        switch (anyStaged, anyUnstaged) {
        case (true, false): self = .staged
        case (true, true): self = .partlyStaged
        default: self = .unstaged
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

/// A node of the tree as a row, once collapsed folders are left out.
struct FileTreeRow: Identifiable, Hashable {
    var node: FileTreeNode
    /// How many folders deep the row is.
    var depth: Int

    var id: String { node.id }
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

    static func sorted(_ entries: [StatusEntry], by sort: FileListSort) -> [StatusEntry] {
        entries.sorted { isOrdered($0, $1, by: sort) }
    }

    /// The entries as a tree of folders, folders before files at each
    /// level. Folders go by name; files by `sort`, where sorting by path
    /// and by name come to the same within one folder.
    static func tree(_ entries: [StatusEntry], sort: FileListSort) -> [FileTreeNode] {
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
        return nodes(in: built, prefix: "", sort: sort)
    }

    /// The rows to show: every node, except those inside a collapsed folder.
    static func rows(_ nodes: [FileTreeNode], collapsed: Set<String>, depth: Int = 0) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        for node in nodes {
            rows.append(FileTreeRow(node: node, depth: depth))
            if node.isFolder, !collapsed.contains(node.id) {
                rows += self.rows(node.children, collapsed: collapsed, depth: depth + 1)
            }
        }
        return rows
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

    private static func nodes(in folder: Folder, prefix: String, sort: FileListSort) -> [FileTreeNode] {
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
            let entries = sorted(child.allEntries, by: .path)
            return FileTreeNode(
                id: path + "/", name: name, kind: .folder(entries: entries),
                children: nodes(in: child, prefix: path + "/", sort: sort)
            )
        }
        let files = sorted(folder.files, by: sort == .status ? .status : .name).map { entry in
            FileTreeNode(id: entry.path, name: entry.path.splitPath.name, kind: .file(entry), children: [])
        }
        return folders + files
    }

    // MARK: Ordering

    private static func isOrdered(_ lhs: StatusEntry, _ rhs: StatusEntry, by sort: FileListSort) -> Bool {
        switch sort {
        case .path:
            return compare(lhs.path, rhs.path)
        case .name:
            let left = lhs.path.splitPath.name, right = rhs.path.splitPath.name
            if left != right { return compare(left, right) }
            return compare(lhs.path, rhs.path)
        case .status:
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left < right }
            return compare(lhs.path, rhs.path)
        }
    }

    /// Paths in the order a person expects: case aside, with numbers by value.
    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs < rhs
        }
    }

    /// Where a file goes when sorting by status.
    static func rank(_ entry: StatusEntry) -> Int {
        switch entry.change {
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
