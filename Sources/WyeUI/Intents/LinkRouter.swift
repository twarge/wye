import Foundation
import Observation

/// Hands a link that did not come in through `onOpenURL` (an intent run
/// inside the app, a clone left by the share extension) to a window.
@MainActor
@Observable
final class LinkRouter {
    static let shared = LinkRouter()

    /// The link waiting for a window to act on it.
    private(set) var pending: WyeLink?

    func request(_ link: WyeLink) {
        pending = link
    }

    /// The waiting link, cleared so that only one window acts on it.
    func take() -> WyeLink? {
        defer { pending = nil }
        return pending
    }
}

/// The repositories open in windows, so an intent can tell when Wye is
/// already working on one and refresh its window afterwards.
@MainActor
enum OpenRepositories {
    private final class WeakModel {
        weak var model: RepositoryModel?
        init(_ model: RepositoryModel) { self.model = model }
    }

    private static var models: [WeakModel] = []

    static func add(_ model: RepositoryModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(WeakModel(model))
    }

    /// A window that closes its repository says so: the model can outlive
    /// the window for a moment, held by work that is winding down.
    static func remove(_ model: RepositoryModel) {
        models.removeAll { $0.model == nil || $0.model === model }
    }

    static func models(for id: UUID) -> [RepositoryModel] {
        models.compactMap(\.model).filter { $0.id == id }
    }

    /// The network operation a window is running on the repository.
    static func activity(for id: UUID) -> String? {
        models(for: id).lazy.compactMap { $0.remotes.activity?.title }.first
    }
}
