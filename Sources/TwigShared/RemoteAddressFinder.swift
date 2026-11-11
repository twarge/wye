import Foundation

/// Finds the address of a git repository in what another app shared: a
/// URL, or text with one somewhere in it.
public enum RemoteAddressFinder {
    /// The first address in `text` that Twig could clone, as it should go
    /// in the clone sheet, or `nil` when there is none.
    ///
    /// Takes HTTPS and SSH URLs (`https://host/owner/project.git`,
    /// `ssh://git@host/owner/project`) and scp-style SSH addresses
    /// (`git@host:owner/project.git`). A web page inside a repository's
    /// site, such as a file or a branch, is cut back to the repository.
    public static func firstAddress(in text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || "<>\"'()[]".contains($0) })
        // Punctuation around an address in a sentence is not part of it.
        let punctuation = CharacterSet(charactersIn: ".,;:!?")
        return words.lazy.compactMap { address(from: $0.trimmingCharacters(in: punctuation)) }.first
    }

    /// The address one word is, if it is one.
    static func address(from word: String) -> String? {
        if let scp = scpAddress(word) { return scp }
        guard let components = URLComponents(string: word),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { return nil }
        switch scheme {
        case "ssh", "git+ssh":
            return components.path.count > 1 ? word : nil
        case "https", "http":
            var parts = components.path.split(separator: "/").map(String.init)
            // Pages within a repository's site: `/owner/project/tree/main/…`,
            // `/owner/project/-/blob/…`. Everything from there on is the page.
            if let cut = parts.firstIndex(where: { pageMarkers.contains($0) }), cut >= 2 {
                parts = Array(parts[..<cut])
            }
            guard !parts.isEmpty else { return nil }
            // A bare host, or one path part, is a site, not a repository,
            // unless it says it is one.
            guard parts.count >= 2 || parts.last?.hasSuffix(".git") == true else { return nil }
            var result = URLComponents()
            result.scheme = scheme
            result.user = components.user
            result.host = host
            result.port = components.port
            result.path = "/" + parts.joined(separator: "/")
            return result.string
        default:
            return nil
        }
    }

    /// Path parts that start a page inside a repository's site rather
    /// than the repository's own address.
    private static let pageMarkers: Set<String> = [
        "-", "tree", "blob", "commit", "commits", "pull", "pulls", "issues", "src", "raw", "blame", "releases",
        "tags", "branches", "compare", "merge_requests", "wiki", "actions"
    ]

    /// `git@host:owner/project.git`: a user, a host, a colon and a path,
    /// with no scheme.
    private static func scpAddress(_ word: String) -> String? {
        guard !word.contains("://"), let at = word.firstIndex(of: "@"),
              let colon = word[at...].firstIndex(of: ":") else { return nil }
        let user = word[..<at]
        let host = word[word.index(after: at)..<colon]
        let path = word[word.index(after: colon)...]
        guard !user.isEmpty, !host.isEmpty, !path.isEmpty, !host.contains("/"),
              user.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        return word
    }
}
