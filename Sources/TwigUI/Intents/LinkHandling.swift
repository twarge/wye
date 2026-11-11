import SwiftUI

extension View {
    /// Acts on `twig://` links in this window: those routed through
    /// `LinkRouter` (from `onOpenURL` or an intent) and an address the
    /// share extension left to clone.
    func handlesTwigLinks(_ actions: WindowActions) -> some View {
        modifier(TwigLinkHandler(actions: actions))
    }
}

private struct TwigLinkHandler: ViewModifier {
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
                guard scenePhase == .active, let address = PendingClone.take() else { return }
                handle(.clone(address))
            }
    }

    private func takeWaiting() {
        if let link = LinkRouter.shared.take() {
            handle(link)
        }
    }

    private func handle(_ link: TwigLink) {
        switch link {
        case .openRepository(let id):
            guard let bookmark = library.bookmarks.first(where: { $0.id == id }) else {
                actions.error = PresentedError(MissingRepository())
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
        "That repository is no longer in Twig’s list. Add it again to open it."
    }
}
