import Foundation
import GitKit
import Observation

/// How histories are shown, for the whole app: the graph, the order, which
/// parents are followed, the headings, what a row shows and its size. Kept in
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
        static let showsHash = "history.showsHash"
        static let showsAuthor = "history.showsAuthor"
        static let showsDate = "history.showsDate"
        static let showsChecks = "history.showsChecks"
        static let hashWidth = "history.hashWidth"
        static let authorWidth = "history.authorWidth"
        static let dateWidth = "history.dateWidth"
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

    /// What a row shows beside the summary.
    var showsHash: Bool {
        didSet { defaults.set(showsHash, forKey: Key.showsHash) }
    }

    var showsAuthor: Bool {
        didSet { defaults.set(showsAuthor, forKey: Key.showsAuthor) }
    }

    var showsDate: Bool {
        didSet { defaults.set(showsDate, forKey: Key.showsDate) }
    }

    /// Whether a commit shows how its checks stand on the hosting services
    /// an account is signed in to.
    var showsChecks: Bool {
        didSet { defaults.set(showsChecks, forKey: Key.showsChecks) }
    }

    /// How wide the columns are, as dragged in the header.
    var columnWidths: HistoryColumnWidths {
        didSet {
            defaults.set(Double(columnWidths.hash), forKey: Key.hashWidth)
            defaults.set(Double(columnWidths.author), forKey: Key.authorWidth)
            defaults.set(Double(columnWidths.date), forKey: Key.dateWidth)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsGraph = defaults.object(forKey: Key.showsGraph) as? Bool ?? true
        firstParentOnly = defaults.bool(forKey: Key.firstParentOnly)
        // Each branch's commits together under its merge, unless date order was chosen.
        order = defaults.string(forKey: Key.order).flatMap(HistoryOptions.Order.init) ?? .topological
        grouping = defaults.string(forKey: Key.grouping).flatMap(Grouping.init) ?? Grouping.none
        rowSize = defaults.string(forKey: Key.rowSize).flatMap(RowSize.init) ?? .regular
        showsHash = defaults.object(forKey: Key.showsHash) as? Bool ?? true
        showsAuthor = defaults.object(forKey: Key.showsAuthor) as? Bool ?? true
        showsDate = defaults.object(forKey: Key.showsDate) as? Bool ?? true
        showsChecks = defaults.object(forKey: Key.showsChecks) as? Bool ?? true
        let standard = HistoryColumnWidths()
        func width(_ key: String, _ fallback: CGFloat) -> CGFloat {
            (defaults.object(forKey: key) as? Double).map { CGFloat($0) } ?? fallback
        }
        columnWidths = HistoryColumnWidths(
            hash: width(Key.hashWidth, standard.hash),
            author: width(Key.authorWidth, standard.author),
            date: width(Key.dateWidth, standard.date)
        )
    }

    /// What a row shows beside the summary, all together.
    var columns: HistoryColumns {
        HistoryColumns(hash: showsHash, author: showsAuthor, date: showsDate)
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

/// What a history's row shows beside its summary. Rows on two lines, on
/// an iPhone, show the author whatever this says.
struct HistoryColumns: Hashable {
    var hash = true
    var author = true
    var date = true
    /// Whether rows keep a place after the message for the mark of a
    /// commit's checks: once the history has any to show.
    var checks = false
}

/// What the rows of a history depend on beyond its commits.
struct HistoryLayout: Hashable {
    var options = HistoryOptions()
    var grouping = HistoryPreferences.Grouping.none
}

extension HistoryPreferences {
    /// Takes up values another device changed, once iCloud has written
    /// them to the defaults.
    func reloadSynced() {
        let fresh = HistoryPreferences(defaults: defaults)
        if showsGraph != fresh.showsGraph { showsGraph = fresh.showsGraph }
        if firstParentOnly != fresh.firstParentOnly { firstParentOnly = fresh.firstParentOnly }
        if order != fresh.order { order = fresh.order }
        if grouping != fresh.grouping { grouping = fresh.grouping }
        if rowSize != fresh.rowSize { rowSize = fresh.rowSize }
        if showsHash != fresh.showsHash { showsHash = fresh.showsHash }
        if showsAuthor != fresh.showsAuthor { showsAuthor = fresh.showsAuthor }
        if showsDate != fresh.showsDate { showsDate = fresh.showsDate }
        if showsChecks != fresh.showsChecks { showsChecks = fresh.showsChecks }
    }
}
