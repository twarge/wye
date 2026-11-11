import GitKit
import SwiftUI

/// What a repository window keeps beside its model: where it has been, for
/// Back and Forward, and whether its settings are on screen.
@MainActor
@Observable
final class RepositoryWindowState {
    let navigation = RepositoryNavigation()
    var isShowingSettings = false
}

extension View {
    /// The app-wide services a repository window takes part in: Back and
    /// Forward, its settings sheet, and the status the widgets show.
    func repositoryWindowServices(_ model: RepositoryModel) -> some View {
        modifier(RepositoryWindowServices(model: model))
    }
}

private struct RepositoryWindowServices: ViewModifier {
    @Bindable var model: RepositoryModel

    func body(content: Content) -> some View {
        @Bindable var state = model.windowState
        let navigation = state.navigation
        content
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.backward") {
                        Task { await navigation.goBack(in: model) }
                    }
                    .disabled(!navigation.canGoBack)
                    .help("Go back to what this window showed before")
                    Button("Forward", systemImage: "chevron.forward") {
                        Task { await navigation.goForward(in: model) }
                    }
                    .disabled(!navigation.canGoForward)
                    .help("Go forward again")
                }
            }
            .onChange(of: model.location, initial: true) {
                navigation.record(model.location)
            }
            .onChange(of: StatusKey(snapshot: model.snapshot, changes: model.workingCopy.entries.count)) {
                model.publishStatus()
            }
            .sheet(isPresented: $state.isShowingSettings) {
                RepositorySettingsView(model: model)
            }
    }

    /// What the published status depends on.
    private struct StatusKey: Equatable {
        var snapshot: RepositorySnapshot?
        var changes: Int
    }
}
