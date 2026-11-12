import SwiftUI

/// At the top of the repository list on iOS, while repositories are still in
/// the app's Documents: offers once to move them all into Wye's location in
/// the Files app, where other apps can open them. Nothing moves until asked,
/// and the offer stays away once dismissed.
struct FilesLocationOffer: View {
    @Environment(RepositoryLibrary.self) private var library
    @AppStorage("filesLocation.offerDismissed") private var isDismissed = false
    @State private var isConfirming = false
    @Environment(WindowActions.self) private var actions

    var body: some View {
        let waiting = library.repositoriesInDocuments
        if !isDismissed, !waiting.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Open Repositories in Other Apps", systemImage: "folder.badge.gearshape")
                        .font(.headline)
                    Text("Repositories in the Wye location of the Files app can be opened and edited by other apps. ^[\(waiting.count) repository](inflect: true) \(waiting.count == 1 ? "is" : "are") still in Wye’s Documents folder, where the Files app shows \(waiting.count == 1 ? "its .git folder" : "their .git folders") too. \(waiting.count == 1 ? "Its" : "Each one’s") menu can also move it later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Move to Files Location") { isConfirming = true }
                            .buttonStyle(.borderedProminent)
                        Button("Dismiss") { isDismissed = true }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
            .confirmationDialog(
                "Move ^[\(waiting.count) repository](inflect: true) to the Files location?",
                isPresented: $isConfirming, titleVisibility: .visible
            ) {
                Button("Move") { moveAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Their folders move, with their history and changes, and stay in Wye’s list as they are. Repositories open in a window or busy with an operation are left where they are.")
            }
        }
    }

    private func moveAll() {
        let failures = library.moveAllToFilesLocation()
        guard !failures.isEmpty else {
            isDismissed = true
            return
        }
        let lines = failures.map { "\($0.name): \($0.error.localizedDescription)" }
        // In the window's strip: the offer itself goes once nothing waits.
        actions.notices.post(Notice(
            .warning, title: "Some Repositories Weren’t Moved",
            message: FilesLocationMoveSummary(lines: lines).localizedDescription
        ))
    }
}

/// The repositories a move left behind, and why.
private struct FilesLocationMoveSummary: LocalizedError {
    var lines: [String]

    var errorDescription: String? {
        (["Some repositories were not moved."] + lines).joined(separator: "\n\n")
    }
}
