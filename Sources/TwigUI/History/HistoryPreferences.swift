import Foundation
import GitKit
import Observation

/// How histories are shown, for the whole app: the graph, the order, which
/// parents are followed, the headings and the row size. Kept in
/// `UserDefaults`, and observable so open histories follow a change at once.
@MainActor
@Observable
final class HistoryPreferences {
    static let shared = HistoryPreferences()

    /// The headings that split a history into stretches of time.
    enum Grouping: String, CaseIterable, Identifiable {
        case day, week, month, none

        var id: Self { self }

        var title: String {
            switch self {
            case .day: "Day"
            case .week: "Week"
            case .month: "Month"
            case .none: "None"
            }
        }
    }

    enum RowSize: String, CaseIterable, Identifiable {
        case compact, regular

        var id: Self { self }

        var title: String {
            switch self {
            case .compact: "Compact"
            case .regular: "Regular"
            }
        }
    }

    private enum Key {
        static let showsGraph = "history.showsGraph"
        static let firstParentOnly = "history.firstParentOnly"
        static let order = "history.order"
        static let grouping = "history.grouping"
        static let rowSize = "history.rowSize"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var showsGraph: Bool {
        didSet { defaults.set(showsGraph, forKey: Key.showsGraph) }
    }

    var firstParentOnly: Bool {
        didSet { defaults.set(firstParentOnly, forKey: Key.firstParentOnly) }
    }

    var order: HistoryOptions.Order {
        didSet { defaults.set(order.rawValue, forKey: Key.order) }
    }

    var grouping: Grouping {
        didSet { defaults.set(grouping.rawValue, forKey: Key.grouping) }
    }

    /// The row size on macOS; iOS chooses by the width it has.
    var rowSize: RowSize {
        didSet { defaults.set(rowSize.rawValue, forKey: Key.rowSize) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsGraph = defaults.object(forKey: Key.showsGraph) as? Bool ?? true
        firstParentOnly = defaults.bool(forKey: Key.firstParentOnly)
        order = defaults.string(forKey: Key.order).flatMap(HistoryOptions.Order.init) ?? .date
        grouping = defaults.string(forKey: Key.grouping).flatMap(Grouping.init) ?? .month
        rowSize = defaults.string(forKey: Key.rowSize).flatMap(RowSize.init) ?? .regular
    }

    /// How the engine reads the history.
    var options: HistoryOptions {
        HistoryOptions(order: order, firstParentOnly: firstParentOnly)
    }

    /// Everything that changes the rows of a history, so it is laid out
    /// again when any of them changes.
    var layout: HistoryLayout {
        HistoryLayout(options: options, grouping: grouping)
    }
}

/// What the rows of a history depend on beyond its commits.
struct HistoryLayout: Hashable {
    var options = HistoryOptions()
    var grouping = HistoryPreferences.Grouping.month
}
