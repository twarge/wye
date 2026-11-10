import GitKit
import SwiftUI

/// Where `HEAD` or a branch has pointed, latest first. Selecting an entry
/// shows the commit it moved to.
struct ReflogView: View {
    var model: RepositoryModel

    var body: some View {
        @Bindable var reflog = model.history.reflog
        List(selection: $reflog.selection) {
            ForEach(reflog.entries) { entry in
                ReflogRow(entry: entry, reference: reflog.reference)
                    .tag(entry.index)
            }
        }
        .listStyle(.plain)
        .overlay {
            if reflog.isLoaded, reflog.entries.isEmpty {
                ContentUnavailableView("No Reflog", systemImage: "list.bullet.rectangle",
                                       description: Text("Nothing has recorded moves of this reference."))
            }
        }
        .navigationTitle(model.name)
        .navigationSubtitle("Reflog")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Reference", selection: $reflog.reference) {
                    Text("HEAD").tag("HEAD")
                    ForEach(model.snapshot?.branches ?? []) { branch in
                        Text(branch.name).tag(branch.id)
                    }
                }
                .help("Choose whose reflog to show")
            }
        }
        .onChange(of: reflog.reference) {
            reflog.selection = nil
        }
        .task(id: ReloadKey(reference: reflog.reference, revision: model.revision)) {
            do {
                try await reflog.load()
            } catch {
                model.error = PresentedError(error)
            }
        }
    }

    private struct ReloadKey: Hashable {
        var reference: String
        var revision: Int
    }
}

private struct ReflogRow: View {
    var entry: ReflogEntry
    var reference: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.message.isEmpty ? "No message" : entry.message)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(verbatim: "\(shortName)@{\(entry.index)}")
                    .font(.smallCode)
                Text(entry.oldID.map { "\($0.abbreviated()) → \(entry.newID.abbreviated())" } ?? entry.newID.abbreviated())
                    .font(.smallCode)
                Spacer(minLength: 4)
                Text(entry.committer.date, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(entry.committer.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var shortName: String {
        reference.hasPrefix("refs/heads/") ? String(reference.dropFirst("refs/heads/".count)) : reference
    }
}
