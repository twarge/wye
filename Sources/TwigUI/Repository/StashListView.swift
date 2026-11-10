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
                    Text(stash.message)
                        .lineLimit(2)
                    Text(stash.date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(stash.id)
                .contextMenu {
                    applyButton(stash)
                    popButton(stash)
                    Divider()
                    dropButton(stash)
                }
                .swipeActions(edge: .leading) {
                    popButton(stash)
                        .tint(.accentColor)
                    applyButton(stash)
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

    private func applyButton(_ stash: Stash) -> some View {
        Button("Apply", systemImage: "arrow.uturn.down") {
            Task { await model.apply(stash) }
        }
        .help("Apply the stash’s changes and keep the stash")
    }

    private func popButton(_ stash: Stash) -> some View {
        Button("Pop", systemImage: "tray.and.arrow.up") {
            Task { await model.pop(stash) }
        }
        .help("Apply the stash’s changes, then drop it")
    }

    private func dropButton(_ stash: Stash) -> some View {
        Button("Drop…", systemImage: "trash", role: .destructive) {
            pendingDrop = stash
        }
        .help("Delete the stash")
    }
}
