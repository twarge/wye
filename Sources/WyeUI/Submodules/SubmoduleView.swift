import GitKit
import SwiftUI

/// A submodule's detail: where it is, where it comes from, the commit
/// recorded against the one checked out, and what can be done with it.
struct SubmoduleView: View {
    var model: RepositoryModel
    var name: String

    var body: some View {
        if let submodule = model.submodule(named: name) {
            Form {
                Section {
                    LabeledContent("Status") {
                        Label(submodule.status.title, systemImage: submodule.status.systemImage)
                    }
                    if let summary = submodule.changes.subtracting(.newCommits).summary {
                        LabeledContent("Changes", value: summary.prefix(1).uppercased() + summary.dropFirst())
                    }
                } footer: {
                    Text(submodule.status.explanation)
                }

                Section {
                    LabeledContent("Path", value: submodule.path)
                    LabeledContent("URL", value: submodule.url ?? "None")
                    if let resolved = submodule.resolvedURL, resolved != submodule.url {
                        LabeledContent("Clones From", value: resolved)
                    }
                    if let branch = submodule.branch {
                        LabeledContent("Branch", value: branch)
                    }
                    if submodule.name != submodule.path {
                        LabeledContent("Name", value: submodule.name)
                    }
                }

                Section {
                    commitRow("Recorded", submodule.recordedID, note: "Not committed")
                    if let head = submodule.headID, head != submodule.recordedID {
                        commitRow("Last Committed", head, note: "")
                    }
                    commitRow("Checked Out", submodule.checkedOutID, note: submodule.status.isCloned ? "Unknown" : "Not cloned")
                } footer: {
                    if submodule.status == .differentCommit {
                        Text("Stage the submodule in the working copy to record the checked-out commit.")
                    }
                }

                Section {
                    HStack {
                        Button("Open", systemImage: "arrow.up.forward.app") {
                            model.nested.opening = .submodule(name)
                        }
                        .disabled(!submodule.status.isCloned)
                        Button("Update", systemImage: "arrow.down.circle") {
                            Task { await model.updateSubmodules([name]) }
                        }
                        .disabled(model.isTransferring)
                        Menu("More", systemImage: "ellipsis.circle") {
                            SubmoduleActions(model: model, submodule: submodule)
                        }
                        .fixedSize()
                    }
                }
            }
            .groupedFormStyle()
            .navigationTitle(submodule.path)
        } else {
            ContentUnavailableView("No Submodule", systemImage: "shippingbox")
        }
    }

    private func commitRow(_ title: String, _ id: OID?, note: String) -> some View {
        LabeledContent(title) {
            Text(id?.abbreviated() ?? note)
                .font(.code)
                .textSelection(.enabled)
        }
    }
}
