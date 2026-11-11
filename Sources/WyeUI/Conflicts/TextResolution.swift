import GitKit

/// The choices made so far in resolving a conflicted text file, and which
/// conflict is being looked at. Kept apart from the view so it can be tested.
struct TextResolution {
    let text: MergeText
    private(set) var resolutions: [Int: ConflictResolution] = [:]
    /// The conflict being looked at, by its position in the file.
    private(set) var current = 0

    init(text: MergeText) {
        self.text = text
    }

    var conflicts: [TextConflict] { text.conflicts }
    var count: Int { conflicts.count }
    var remaining: Int { count - resolutions.count }
    var isComplete: Bool { remaining == 0 }
    /// The file as it will be saved, once every conflict is resolved.
    var result: String? { text.merged(resolutions) }

    var currentConflict: TextConflict? {
        conflicts.indices.contains(current) ? conflicts[current] : nil
    }

    var canGoBack: Bool { current > 0 }
    var canGoForward: Bool { current < count - 1 }

    func resolution(of position: Int) -> ConflictResolution? {
        resolutions[position]
    }

    mutating func go(to position: Int) {
        guard conflicts.indices.contains(position) else { return }
        current = position
    }

    mutating func next() { go(to: current + 1) }
    mutating func previous() { go(to: current - 1) }

    /// Settles the current conflict and moves on to the next one still
    /// open, after it or else before it, so a run of choices needs no
    /// navigating in between.
    mutating func resolveCurrent(_ resolution: ConflictResolution) {
        guard currentConflict != nil else { return }
        resolutions[current] = resolution
        let open = conflicts.indices.filter { resolutions[$0] == nil }
        if let next = open.first(where: { $0 > current }) ?? open.first {
            current = next
        }
    }

    /// Opens the current conflict again.
    mutating func clearCurrent() {
        resolutions[current] = nil
    }

    /// The text to start editing the current conflict from: what it is
    /// resolved to so far, or else our side.
    var draftForCurrent: String {
        guard let conflict = currentConflict else { return "" }
        let lines = conflict.lines(resolvedBy: resolutions[current] ?? .ours, lineEnding: "\n")
        return lines.map(\.withoutLineEnding).joined(separator: "\n")
    }

    // MARK: The result, for showing

    struct Segment: Identifiable, Hashable {
        enum Kind: Hashable {
            case merged
            case resolved(conflict: Int)
            /// Shown with git's markers, as it would be without a choice.
            case open(conflict: Int)
        }

        let id: Int
        let kind: Kind
        let text: String

        var conflict: Int? {
            switch kind {
            case .merged: nil
            case .resolved(let conflict), .open(let conflict): conflict
            }
        }
    }

    /// The merged file in pieces: merged runs, and each conflict as resolved
    /// or, while open, between conflict markers named for the sides.
    func segments(oursLabel: String, theirsLabel: String) -> [Segment] {
        var segments: [Segment] = []
        var position = 0
        for (id, region) in text.regions.enumerated() {
            switch region {
            case .merged(let lines):
                segments.append(Segment(id: id, kind: .merged, text: Self.display(lines)))
            case .conflict(let conflict):
                if let resolution = resolutions[position] {
                    let lines = conflict.lines(resolvedBy: resolution, lineEnding: text.lineEnding)
                    segments.append(Segment(id: id, kind: .resolved(conflict: position), text: Self.display(lines)))
                } else {
                    let marked = ["<<<<<<< \(oursLabel)"] + conflict.ours.map(\.withoutLineEnding)
                        + ["======="] + conflict.theirs.map(\.withoutLineEnding) + [">>>>>>> \(theirsLabel)"]
                    segments.append(Segment(id: id, kind: .open(conflict: position), text: marked.joined(separator: "\n")))
                }
                position += 1
            }
        }
        return segments
    }

    static func display(_ lines: [String]) -> String {
        lines.map(\.withoutLineEnding).joined(separator: "\n")
    }
}
