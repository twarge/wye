import Foundation
import GitKit
import Observation

/// The places a window has shown, for Back and Forward: a bounded list
/// behind the current place and the places gone back from.
struct NavigationHistory<Location: Equatable> {
    let capacity: Int
    private(set) var current: Location?
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []

    init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Notes that the window now shows `location`. A place that only fills
    /// in the one before (`refines`), such as a commit selected in the
    /// history just switched to, replaces it rather than adding a step.
    mutating func visit(_ location: Location, refines: (Location, Location) -> Bool = { _, _ in false }) {
        guard location != current else { return }
        if let current, refines(current, location) {
            self.current = location
            return
        }
        if let current {
            backStack.append(current)
            if backStack.count > capacity {
                backStack.removeFirst(backStack.count - capacity)
            }
        }
        current = location
        forwardStack.removeAll()
    }

    /// Corrects the current place without making a step, for when showing
    /// a place settled somewhere slightly different.
    mutating func replaceCurrent(with location: Location) {
        current = location
    }

    /// Steps back, returning the place to show.
    mutating func goBack() -> Location? {
        guard let previous = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = previous
        return previous
    }

    /// Steps forward again, returning the place to show.
    mutating func goForward() -> Location? {
        guard let next = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = next
        return next
    }
}

/// Where a repository window is: what the sidebar selects, and the commit
/// or file selected in the list beside it.
struct RepositoryLocation: Hashable {
    var sidebar: SidebarItem?
    var commit: OID?
    var file: String?
    /// The selected reflog entry, by its index.
    var reflogEntry: Int?

    /// Whether `next` is `self` with its detail chosen: the same sidebar
    /// item, where nothing was selected yet.
    func isRefined(by next: RepositoryLocation) -> Bool {
        sidebar == next.sidebar && commit == nil && file == nil && reflogEntry == nil
    }
}

/// Back and Forward for one repository window.
@MainActor
@Observable
final class RepositoryNavigation {
    private(set) var history = NavigationHistory<RepositoryLocation>(capacity: 50)
    /// Set while going back or forward, so the moves that makes are not
    /// recorded as visits of their own.
    private var isMoving = false

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    func record(_ location: RepositoryLocation) {
        guard !isMoving else { return }
        history.visit(location) { $0.isRefined(by: $1) }
    }

    func goBack(in model: RepositoryModel) async {
        guard !isMoving, let location = history.goBack() else { return }
        await show(location, in: model)
    }

    func goForward(in model: RepositoryModel) async {
        guard !isMoving, let location = history.goForward() else { return }
        await show(location, in: model)
    }

    private func show(_ location: RepositoryLocation, in model: RepositoryModel) async {
        isMoving = true
        defer { isMoving = false }
        model.selection = location.sidebar
        switch location.sidebar {
        case .workingCopy:
            model.workingCopy.selection = location.file
        case .stashes:
            model.selectedStash = location.commit
        case .reflog:
            model.history.reflog.selection = location.reflogEntry
        case let item?:
            guard let scope = item.historyScope else { break }
            await model.history.show(scope)
            if let commit = location.commit {
                // The window's own switch to this history may still be reading it.
                for _ in 0..<20 {
                    if await model.history.reveal(commit) { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        case nil:
            break
        }
        // Whatever the moves settled on is where the window now is.
        history.replaceCurrent(with: model.location)
    }
}

extension RepositoryModel {
    /// Where the window is, for Back and Forward.
    var location: RepositoryLocation {
        switch selection {
        case .workingCopy:
            RepositoryLocation(sidebar: selection, file: workingCopy.selection)
        case .stashes:
            RepositoryLocation(sidebar: selection, commit: selectedStash)
        case .reflog:
            RepositoryLocation(sidebar: selection, reflogEntry: history.reflog.selection)
        case let item? where item.historyScope != nil:
            RepositoryLocation(sidebar: selection, commit: history.selection)
        default:
            RepositoryLocation(sidebar: selection)
        }
    }
}
