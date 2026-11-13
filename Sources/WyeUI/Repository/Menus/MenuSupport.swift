import GitKit
import SwiftUI

/// How the menus name things in their items: as they are, without quotes,
/// as in Merge into main…. A context menu never names what it was opened
/// on: it calls it Here, as in Rebase main onto Here…, or leaves it out,
/// as in Check Out.
enum MenuNames {
    static func name(_ name: String) -> String {
        name
    }

    /// A commit by its short hash.
    static func name(_ id: OID) -> String {
        id.abbreviated()
    }

    /// The checked-out branch, or `HEAD` when it is detached, as in Merge
    /// topic into main…. Unquoted, a word such as "Current" would read as
    /// a branch's name.
    @MainActor
    static func current(_ model: RepositoryModel) -> String {
        model.headBranchName ?? "HEAD"
    }
}

/// The items every reference's menu ends with: exporting its files and
/// comparing it, then finding it in the history and copying its name.
struct ReferenceFooterItems: View {
    var model: RepositoryModel
    /// The name as people write it: `main`, `origin/main`, `v1.0`.
    var name: String
    var target: OID?
    /// "Copy Branch Name", "Copy Tag Name"…
    var copyTitle: String

    var body: some View {
        Section {
            Button("Export Files from Here…", systemImage: "archivebox") {
                if let target { Task { await model.exportFiles(of: target, named: name) } }
            }
            .disabled(target == nil)
            .help("Save the files at this revision as a zip archive")
            Button("Compare With…", systemImage: "arrow.left.arrow.right") {
                model.present(.pickRevision(.compare(name)))
            }
        }
        Section {
            Button("Reveal in History", systemImage: "scope") {
                if let target { Task { await model.revealInFullHistory(target) } }
            }
            .disabled(target == nil)
            Button(copyTitle, systemImage: "doc.on.doc") {
                Platform.copyToClipboard(name)
            }
        }
    }
}
