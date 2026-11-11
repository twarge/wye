import GitKit
import SwiftUI

/// Branches laid out as a tree, with names like `feature/login` grouped
/// into a `feature` folder.
struct BranchFolderNode: Identifiable {
    /// Unique across the sidebar, and stable, so a folder stays open or
    /// closed as the branches change.
    let id: String
    /// The folder's name, or the branch's name within its folder.
    let name: String
    /// The branch, for a leaf; `nil` for a folder.
    let branch: Branch?
    let children: [BranchFolderNode]

    /// Builds the tree from branches in display order. `path` gives the name
    /// to split, such as `feature/login` for `origin/feature/login`. Folders
    /// come before the branches beside them.
    static func tree(
        of branches: [Branch], path: (Branch) -> String, idPrefix: String
    ) -> [BranchFolderNode] {
        build(branches.map { (path($0).split(separator: "/").map(String.init), $0) }, idPrefix: idPrefix)
    }

    private static func build(_ entries: [(components: [String], branch: Branch)], idPrefix: String) -> [BranchFolderNode] {
        var folders: [String: [(components: [String], branch: Branch)]] = [:]
        var folderOrder: [String] = []
        var leaves: [BranchFolderNode] = []
        for entry in entries {
            if entry.components.count > 1 {
                let folder = entry.components[0]
                if folders[folder] == nil { folderOrder.append(folder) }
                folders[folder, default: []].append((Array(entry.components.dropFirst()), entry.branch))
            } else {
                leaves.append(BranchFolderNode(
                    id: entry.branch.id, name: entry.components.first ?? entry.branch.name,
                    branch: entry.branch, children: []
                ))
            }
        }
        let folderNodes = folderOrder.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { folder in
            let id = idPrefix + folder + "/"
            return BranchFolderNode(
                id: id, name: folder, branch: nil, children: build(folders[folder] ?? [], idPrefix: id)
            )
        }
        return folderNodes + leaves
    }

    /// Whether the folder holds `branch`, by full reference name, at any depth.
    func contains(_ branch: String) -> Bool {
        children.contains { $0.branch?.id == branch || $0.contains(branch) }
    }
}

/// Rows for a branch tree: a disclosure group per folder, and `row` for
/// each branch.
struct BranchFolderRows<Row: View>: View {
    var nodes: [BranchFolderNode]
    /// Folders the user opened or closed, against their default: closed,
    /// except one holding the checked-out branch.
    @Binding var toggled: Set<String>
    var headBranch: String?
    @ViewBuilder var row: (Branch, String) -> Row

    var body: some View {
        ForEach(nodes) { node in
            if let branch = node.branch {
                row(branch, node.name)
            } else {
                DisclosureGroup(isExpanded: isExpanded(node)) {
                    BranchFolderRows(nodes: node.children, toggled: $toggled, headBranch: headBranch, row: row)
                } label: {
                    Label(node.name, systemImage: "folder")
                }
            }
        }
    }

    private func isExpanded(_ node: BranchFolderNode) -> Binding<Bool> {
        let opensByDefault = headBranch.map(node.contains) ?? false
        return Binding {
            opensByDefault != toggled.contains(node.id)
        } set: { expanded in
            if expanded == opensByDefault {
                toggled.remove(node.id)
            } else {
                toggled.insert(node.id)
            }
        }
    }
}
