import Clibgit2
import Foundation

/// How a diff is read: how much unchanged text surrounds each change, and
/// which differences in whitespace count as changes.
public struct DiffOptions: Hashable, Sendable {
    /// Which whitespace differences a diff leaves out.
    public enum Whitespace: String, Hashable, Sendable, CaseIterable {
        /// Every difference counts, as git shows by default.
        case none
        /// Whitespace is ignored altogether (`git diff -w`).
        case all
        /// A change in the amount of whitespace is ignored, as is whitespace
        /// at the end of a line (`git diff -b`).
        case amount
        /// Only whitespace at the end of a line is ignored
        /// (`git diff --ignore-space-at-eol`).
        case endOfLine
    }

    /// Unchanged lines shown before and after each change.
    public var contextLines: Int
    public var whitespace: Whitespace

    public init(contextLines: Int = 3, whitespace: Whitespace = .none) {
        self.contextLines = contextLines
        self.whitespace = whitespace
    }

    /// git's own defaults.
    public static let standard = DiffOptions()

    /// Whether a diff read with these options says exactly how the two sides
    /// differ, so parts of it can be staged. One that leaves out whitespace
    /// changes does not: its unchanged lines may not match either side.
    public var isExact: Bool { whitespace == .none }

    /// Sets these options on libgit2's.
    func apply(to options: inout git_diff_options) {
        options.context_lines = UInt32(max(0, contextLines))
        switch whitespace {
        case .none: break
        case .all: options.flags |= GIT_DIFF_IGNORE_WHITESPACE.rawValue
        case .amount: options.flags |= GIT_DIFF_IGNORE_WHITESPACE_CHANGE.rawValue
        case .endOfLine: options.flags |= GIT_DIFF_IGNORE_WHITESPACE_EOL.rawValue
        }
    }
}
