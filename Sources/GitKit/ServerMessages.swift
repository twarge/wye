import Foundation

/// What a git server said during a fetch or a push, made readable: the
/// text git prints after "remote:".
public enum ServerMessages {
    /// The lines worth showing, in order. A server draws its progress by
    /// sending a line again and again over itself, so only the last
    /// writing of each line counts, and the counting itself is left out:
    /// the transfer's own progress has said it.
    public static func lines(in output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                let written = line.split(separator: "\r", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .last { !$0.isEmpty }
                guard let written, !isProgress(written) else { return nil }
                return written
            }
    }

    private static let progressPrefixes = [
        "Enumerating objects:", "Counting objects:", "Compressing objects:", "Resolving deltas:",
        "Receiving objects:", "Writing objects:", "Total "
    ]

    static func isProgress(_ line: String) -> Bool {
        progressPrefixes.contains { line.hasPrefix($0) }
    }

    /// A page the server invites the user to open.
    public struct Link: Hashable, Sendable {
        public var url: URL
        /// Whether the page opens a pull request or a merge request for
        /// what was just pushed, as the hosting services offer.
        public var opensPullRequest: Bool
    }

    /// The first web address among the lines, if the server sent one.
    public static func link(in lines: [String]) -> Link? {
        for line in lines {
            for word in line.split(whereSeparator: \.isWhitespace) {
                guard word.hasPrefix("https://") || word.hasPrefix("http://"),
                      let url = URL(string: String(word)), url.host() != nil else { continue }
                let path = url.path().lowercased()
                let opens = ["/pull/new", "/merge_requests/new", "/pull-requests/new", "/compare/"]
                    .contains { path.contains($0) }
                return Link(url: url, opensPullRequest: opens)
            }
        }
        return nil
    }
}
