import Foundation
import GitKit

/// An issue tracker the user names for a repository, for references such
/// as `ABC-123` that the hosting service does not know. Stored in the
/// repository's interface state; see `RepositoryInterfaceState.issueTrackers`.
struct IssueTracker: Codable, Hashable, Sendable {
    /// What a reference looks like, as a regular expression. Jira-style
    /// keys by default.
    var pattern: String
    /// The page for a reference: `$0` stands for the whole reference and
    /// `$1`, `$2`… for the pattern's groups, as in
    /// `https://example.atlassian.net/browse/$0`.
    var urlTemplate: String

    static let jiraPattern = "\\b[A-Z][A-Z0-9]+-[0-9]+\\b"

    init(pattern: String = IssueTracker.jiraPattern, urlTemplate: String) {
        self.pattern = pattern
        self.urlTemplate = urlTemplate
    }

    /// Whether the pattern is a regular expression and the template makes
    /// an address, for a settings screen to check before saving.
    var isValid: Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
            && URL(string: urlTemplate.replacingOccurrences(of: "$", with: "")) != nil
            && urlTemplate.contains("$")
    }
}

/// Finds the links in a commit message: web addresses, and references to
/// issues and pull requests on the hosting service or a tracker the user
/// named. Pure, so it can be tested without a window.
struct MessageLinker {
    struct Link: Hashable {
        let range: Range<String.Index>
        let url: URL
    }

    /// The repository on its hosting service, for `#123` and the like.
    var hosted: HostedRepository?
    var trackers: [IssueTracker] = []

    /// The links in `text`, in order, none overlapping. Where two kinds of
    /// reference claim the same text, the earlier kind in this list wins:
    /// addresses, `owner/repo#123`, `GH-123`, `!123`, the user's trackers,
    /// then `#123`.
    func links(in text: String) -> [Link] {
        var links: [Link] = []
        func claim(_ range: Range<String.Index>, _ url: URL?) {
            guard let url, !links.contains(where: { $0.range.overlaps(range) }) else { return }
            links.append(Link(range: range, url: url))
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, let range = Range(match.range, in: text),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                claim(range, url)
            }
        }
        if let hosted {
            for match in Self.matches(Self.crossRepository, in: text) {
                claim(match.range, hosted.issueURL(match.groups[1], inProject: match.groups[0]))
            }
            if hosted.kind == .github {
                for match in Self.matches(Self.githubPrefixed, in: text) {
                    claim(match.range, hosted.issueURL(match.groups[0]))
                }
            }
            if hosted.kind == .gitlab {
                for match in Self.matches(Self.mergeRequest, in: text) {
                    claim(match.range, hosted.mergeRequestURL(match.groups[0]))
                }
            }
        }
        for tracker in trackers {
            guard let expression = try? NSRegularExpression(pattern: tracker.pattern) else { continue }
            for match in Self.matches(expression, in: text) {
                claim(match.range, Self.url(from: tracker.urlTemplate, whole: String(text[match.range]), groups: match.groups))
            }
        }
        if let hosted {
            for match in Self.matches(Self.issue, in: text) {
                claim(match.range, hosted.issueURL(match.groups[0]))
            }
        }
        return links.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `text` with its links made into links.
    func attributed(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for link in links(in: text) {
            guard let lower = AttributedString.Index(link.range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(link.range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = link.url
        }
        return attributed
    }

    // MARK: Patterns

    /// `#123`, not inside a word, a URL fragment or an HTML entity.
    private static let issue = expression("(?<![\\w/#&])#([0-9]+)\\b")
    /// `owner/repo#123`.
    private static let crossRepository = expression("(?<![\\w/.-])([A-Za-z0-9][\\w.-]*/[A-Za-z0-9][\\w.-]*)#([0-9]+)\\b")
    /// `GH-123`, GitHub's other way of writing an issue.
    private static let githubPrefixed = expression("\\bGH-([0-9]+)\\b")
    /// `!123`, a GitLab merge request.
    private static let mergeRequest = expression("(?<![\\w!])!([0-9]+)\\b")

    private static func expression(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed and known to compile.
        try! NSRegularExpression(pattern: pattern)
    }

    private struct Match {
        let range: Range<String.Index>
        /// The capture groups' text, from the first group on; empty for a
        /// group that took part in nothing.
        let groups: [String]
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> [Match] {
        expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let groups = (1..<max(result.numberOfRanges, 1)).map { index in
                Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            return Match(range: range, groups: groups)
        }
    }

    /// Fills in a tracker's template, percent-encoding what it puts in.
    static func url(from template: String, whole: String, groups: [String]) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#&=")
        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        var result = template
        // Higher groups first, so `$1` does not eat the start of `$10`.
        for (index, group) in groups.enumerated().reversed() {
            result = result.replacingOccurrences(of: "$\(index + 1)", with: encoded(group))
        }
        result = result.replacingOccurrences(of: "$0", with: encoded(whole))
        return URL(string: result)
    }
}

extension HostedRepository {
    /// An issue's page, on this repository or, given as `owner/repo`,
    /// another on the same host. GitHub sends an issue number that is a
    /// pull request on to the pull request. `nil` where the host's
    /// addresses are unknown.
    func issueURL(_ number: String, inProject project: String? = nil) -> URL? {
        let path: String? = switch kind {
        case .github, .gitea, .bitbucket: "issues/\(number)"
        case .gitlab: "-/issues/\(number)"
        case .sourcehut, .other: nil
        }
        guard let path, let page = page(of: project) else { return nil }
        return URL(string: page + "/" + path)
    }

    /// A GitLab merge request's page.
    func mergeRequestURL(_ number: String) -> URL? {
        guard kind == .gitlab else { return nil }
        return URL(string: url.absoluteString + "/-/merge_requests/\(number)")
    }

    /// The address of this repository, or of `project` on the same host.
    private func page(of project: String?) -> String? {
        guard let project else { return url.absoluteString }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/" + project
        return components.url?.absoluteString
    }
}

extension RepositoryModel {
    /// What finds links in this repository's commit messages: its trackers,
    /// and the hosting service of the remote it most likely lives on.
    var messageLinker: MessageLinker {
        let remote = defaultRemoteName ?? "origin"
        return MessageLinker(hosted: hostedRepository(remote: remote), trackers: interface.issueTrackers)
    }
}
