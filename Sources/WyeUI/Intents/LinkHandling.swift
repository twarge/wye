import SwiftUI
import WyeShared

extension View {
    /// Acts on `wye://` links in this window: those routed through
    /// `LinkRouter` (from `onOpenURL` or an intent) and an address the
    /// share extension left to clone.
    func handlesWyeLinks(_ actions: WindowActions) -> some View {
        modifier(WyeLinkHandler(actions: actions))
    }
}

private struct WyeLinkHandler: ViewModifier {
    let actions: WindowActions

    @Environment(RepositoryLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                takeWaiting()
            }
            .onChange(of: LinkRouter.shared.pending) {
                takeWaiting()
            }
            .onChange(of: scenePhase, initial: true) {
                guard scenePhase == .active else { return }
                // What a widget asked for while the app was not running.
                WidgetActionRunner.runPending()
                guard let address = PendingClone.take() else { return }
                handle(.clone(address))
            }
    }

    private func takeWaiting() {
        if let link = LinkRouter.shared.take() {
            handle(link)
        }
    }

    private func handle(_ link: WyeLink) {
        switch link {
        case .openRepository(let id):
            guard let bookmark = library.bookmarks.first(where: { $0.id == id }) else {
                actions.notices.post(MissingRepository())
                return
            }
            actions.open(bookmark)
        case .clone(let address):
            actions.cloneAddress = address
            actions.isCloning = true
        }
    }
}

private struct MissingRepository: LocalizedError {
    var errorDescription: String? {
        "That repository is no longer in Wye’s list. Add it again to open it."
    }
}
