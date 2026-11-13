import GitKit
import SwiftUI

/// What a repository window keeps beside its model: where it has been, for
/// View ▸ Back and Forward, and whether its settings are on screen.
@MainActor
@Observable
final class RepositoryWindowState {
    let navigation = RepositoryNavigation()
    var isShowingSettings = false
}

extension View {
    /// The app-wide services a repository window takes part in: the places
    /// View ▸ Back and Forward go, its settings sheet, and the status the
    /// widgets show.
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
