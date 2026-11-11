import GitKit
import SwiftUI

struct StashListView: View {
    @Bindable var model: RepositoryModel

    /// The stash waiting for its drop to be confirmed.
    @State private var pendingDrop: Stash?

    var body: some View {
        let stashes = model.snapshot?.stashes ?? []
        List(selection: $model.selectedStash) {
            ForEach(stashes) { stash in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if stash.isSnapshot {
                            Label("Snapshot", systemImage: "camera")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                                .help("A snapshot: its changes were left in place when it was made")
                        }
                        Text(stash.isSnapshot ? stash.title : stash.message)
                            .lineLimit(2)
                    }
                    Text(stash.date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(stash.id)
                .contextMenu {
                    StashMenu(model: model, stash: stash) { pendingDrop = stash }
                }
                .swipeActions(edge: .leading) {
                    StashPopButton(model: model, stash: stash)
                        .tint(.accentColor)
                    StashApplyButton(model: model, stash: stash)
                }
                .swipeActions(edge: .trailing) {
                    // Not destructive in role: that would take the row away
                    // before the drop is confirmed.
                    Button("Drop…", systemImage: "trash") { pendingDrop = stash }
                        .tint(.red)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if stashes.isEmpty {
                ContentUnavailableView(
                    "No Stashes",
                    systemImage: "tray",
                    description: Text("Changes you set aside appear here.")
                )
            }
        }
        .navigationTitle(model.name)
        .navigationSubtitle("Stashes")
        .confirmationDialog(
            "Drop This Stash?",
            isPresented: Binding { pendingDrop != nil } set: { if !$0 { pendingDrop = nil } },
            titleVisibility: .visible,
            presenting: pendingDrop
        ) { stash in
            Button("Drop Stash", role: .destructive) {
                Task { await model.drop(stash) }
            }
        } message: { stash in
            Text("“\(stash.message)” is deleted, and the changes it holds are lost.")
        }
    }
}
