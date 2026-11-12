import Foundation
import GitKit
import Observation

/// The app-wide settings for every diff: how it is read, how it is drawn,
/// and when commit detail starts with its files folded. Kept in
/// `UserDefaults`, and observable so open diffs follow a change at once.
@MainActor
@Observable
final class DiffPreferences {
    static let shared = DiffPreferences()

    /// The context line counts offered.
    static let contextChoices = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 25, 50]
    static let tabWidthChoices = [2, 3, 4, 8]
    /// File counts above which commit detail folds every file; `nil` never folds.
    static let collapseChoices: [Int?] = [nil, 5, 10, 25, 50]

    private enum Key {
        static let contextLines = "diff.contextLines"
        static let whitespace = "diff.ignoreWhitespace"
        static let showsInvisibles = "diff.showsInvisibles"
        static let tabWidth = "diff.tabWidth"
        static let collapseThreshold = "diff.autoCollapseFileCount"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Unchanged lines around each change.
    var contextLines: Int {
        didSet { defaults.set(contextLines, forKey: Key.contextLines) }
    }

    var whitespace: DiffOptions.Whitespace {
        didSet { defaults.set(whitespace.rawValue, forKey: Key.whitespace) }
    }

    /// Whether spaces and tabs are drawn as dots and arrows.
    var showsInvisibles: Bool {
        didSet { defaults.set(showsInvisibles, forKey: Key.showsInvisibles) }
    }

    /// How many columns a tab takes.
    var tabWidth: Int {
        didSet { defaults.set(tabWidth, forKey: Key.tabWidth) }
    }

    /// Commit detail starts with every file folded when a commit changes
    /// more files than this; `nil` always starts unfolded.
    var collapseThreshold: Int? {
        didSet { defaults.set(collapseThreshold ?? 0, forKey: Key.collapseThreshold) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let context = defaults.object(forKey: Key.contextLines) as? Int ?? 3
        contextLines = Self.contextChoices.contains(context) ? context : 3
        whitespace = defaults.string(forKey: Key.whitespace).flatMap(DiffOptions.Whitespace.init) ?? .none
        showsInvisibles = defaults.bool(forKey: Key.showsInvisibles)
        let tab = defaults.object(forKey: Key.tabWidth) as? Int ?? 4
        tabWidth = Self.tabWidthChoices.contains(tab) ? tab : 4
        // Stored as 0 for "never", which `object(forKey:)` tells from unset.
        let threshold = defaults.object(forKey: Key.collapseThreshold) as? Int ?? 25
        collapseThreshold = threshold > 0 ? threshold : nil
    }

    /// The options every diff is read with.
    var options: DiffOptions {
        DiffOptions(contextLines: contextLines, whitespace: whitespace)
    }

    /// The files commit detail starts with folded: all of them past the
    /// threshold, otherwise none.
    func initiallyCollapsed(_ files: [FileDiff]) -> Set<String> {
        Self.initiallyCollapsed(files.map(\.id), threshold: collapseThreshold)
    }

    /// The IDs of the files to fold, out of `ids`, one per file.
    nonisolated static func initiallyCollapsed(_ ids: [String], threshold: Int?) -> Set<String> {
        guard let threshold, ids.count > threshold else { return [] }
        return Set(ids)
    }
}

extension DiffOptions.Whitespace {
    var title: String {
        switch self {
        case .none: "Show All Changes"
        case .all: "Ignore All Whitespace"
        case .amount: "Ignore Changes in Amount"
        case .endOfLine: "Ignore at End of Line"
        }
    }
}

/// How a diff line's text is drawn: tabs laid out to the tab width, and
/// with invisibles shown, spaces as dots and tabs as arrows.
struct DiffTextStyle: Hashable {
    var tabWidth = 4
    var showsInvisibles = false

    /// A stretch of the line, either its text or a drawn invisible.
    struct Run: Hashable {
        var text: String
        var isInvisible: Bool
    }

    /// The line as runs to draw. Plain text with no tabs comes back whole.
    func runs(_ text: String) -> [Run] {
        guard showsInvisibles || text.contains("\t") else { return [Run(text: text, isInvisible: false)] }
        var runs: [Run] = []
        var current = ""
        var currentIsInvisible = false
        var column = 0

        func append(_ piece: String, invisible: Bool) {
            if invisible != currentIsInvisible, !current.isEmpty {
                runs.append(Run(text: current, isInvisible: currentIsInvisible))
                current = ""
            }
            currentIsInvisible = invisible
            current += piece
        }

        let width = max(1, tabWidth)
        for character in text {
            switch character {
            case "\t":
                let span = width - column % width
                if showsInvisibles {
                    append("→" + String(repeating: " ", count: span - 1), invisible: true)
                } else {
                    append(String(repeating: " ", count: span), invisible: false)
                }
                column += span
            case " " where showsInvisibles:
                append("·", invisible: true)
                column += 1
            default:
                append(String(character), invisible: false)
                column += 1
            }
        }
        if !current.isEmpty { runs.append(Run(text: current, isInvisible: currentIsInvisible)) }
        return runs
    }
}

extension DiffPreferences {
    /// Takes up values another device changed, once iCloud has written
    /// them to the defaults.
    func reloadSynced() {
        let fresh = DiffPreferences(defaults: defaults)
        if contextLines != fresh.contextLines { contextLines = fresh.contextLines }
        if whitespace != fresh.whitespace { whitespace = fresh.whitespace }
        if showsInvisibles != fresh.showsInvisibles { showsInvisibles = fresh.showsInvisibles }
        if tabWidth != fresh.tabWidth { tabWidth = fresh.tabWidth }
        if collapseThreshold != fresh.collapseThreshold { collapseThreshold = fresh.collapseThreshold }
    }
}
