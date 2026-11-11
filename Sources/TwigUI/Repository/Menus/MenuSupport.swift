import GitKit
import SwiftUI

/// How the context menus name things in their items: in curly quotes, as
/// in Check Out “main”.
enum MenuNames {
    static func quoted(_ name: String) -> String {
        "“\(name)”"
    }

    /// A commit by its short hash.
    static func quoted(_ id: OID) -> String {
        quoted(id.abbreviated())
    }

    /// The checked-out branch, or "Current" when `HEAD` is detached, as
    /// in Merge “topic” into “main”….
    @MainActor
    static func current(_ model: RepositoryModel) -> String {
        model.headBranchName.map(quoted) ?? "Current"
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
        let quoted = MenuNames.quoted(name)
        Section {
            Button("Export Files from \(quoted)…", systemImage: "archivebox") {
                if let target { Task { await model.exportFiles(of: target, named: name) } }
            }
            .disabled(target == nil)
            .help("Save the files at this revision as a zip archive")
            Button("Compare \(quoted) With…", systemImage: "arrow.left.arrow.right") {
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
