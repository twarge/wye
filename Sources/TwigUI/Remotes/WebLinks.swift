import Foundation
import GitKit

/// A repository's pages on its hosting service, worked out from a remote
/// URL: `https://host/owner/project(.git)`, `ssh://git@host/owner/project`,
/// or the short `git@host:owner/project.git`.
struct HostedRepository: Hashable {
    /// The kinds of host whose page addresses differ.
    enum Kind: Hashable {
        case github
        case gitlab
        case bitbucket
        /// Gitea and Forgejo, Codeberg among them.
        case gitea
        case sourcehut
        /// A host Twig does not know: only the repository page is guessed.
        case other
    }

    /// The repository's page, such as `https://github.com/owner/project`.
    let url: URL
    let kind: Kind

    init?(remoteURL: String) {
        guard let parts = Self.parts(of: remoteURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        let (scheme, host) = (parts.scheme, parts.host)
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !host.isEmpty, !path.isEmpty,
              let url = URL(string: "\(scheme)://\(host)/\(Self.encode(path))") else { return nil }
        self.url = url
        kind = Self.kind(of: host)
    }

    /// A branch's page, or `nil` where the host's addresses are unknown.
    func url(forBranch branch: String) -> URL? {
        let encoded = Self.encode(branch)
        let path: String? = switch kind {
        case .github, .sourcehut: "tree/\(encoded)"
        case .gitlab: "-/tree/\(encoded)"
        case .bitbucket: "src/\(encoded)"
        case .gitea: "src/branch/\(encoded)"
        case .other: nil
        }
        return path.flatMap { URL(string: url.absoluteString + "/" + $0) }
    }

    /// A commit's page, or `nil` where the host's addresses are unknown.
    func url(forCommit id: OID) -> URL? {
        let path: String? = switch kind {
        case .github, .gitea, .sourcehut: "commit/\(id.hex)"
        case .gitlab: "-/commit/\(id.hex)"
        case .bitbucket: "commits/\(id.hex)"
        case .other: nil
        }
        return path.flatMap { URL(string: url.absoluteString + "/" + $0) }
    }

    /// The page that starts a pull request (a merge request on GitLab)
    /// from a branch on this repository, into `base` when one is given and
    /// into the repository's default branch otherwise. `nil` where the host
    /// has no such page or its addresses are unknown.
    func newPullRequestURL(forBranch branch: String, into base: String? = nil) -> URL? {
        let head = Self.encode(branch)
        let path: String? = switch kind {
        case .github, .gitea:
            "compare/" + (base.map { Self.encode($0) + "..." } ?? "") + head + (kind == .github ? "?expand=1" : "")
        case .gitlab:
            "-/merge_requests/new?merge_request%5Bsource_branch%5D=\(Self.encodeQuery(branch))"
                + (base.map { "&merge_request%5Btarget_branch%5D=\(Self.encodeQuery($0))" } ?? "")
        case .bitbucket:
            "pull-requests/new?source=\(Self.encodeQuery(branch))" + (base.map { "&dest=\(Self.encodeQuery($0))" } ?? "")
        case .sourcehut, .other:
            // sourcehut takes patches by email rather than pull requests.
            nil
        }
        return path.flatMap { URL(string: url.absoluteString + "/" + $0) }
    }

    /// Percent-encodes a query value, slashes included.
    private static func encodeQuery(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: Parsing

    /// The scheme for the web page, the host and the repository path.
    private static func parts(of remoteURL: String) -> (scheme: String, host: String, path: String)? {
        if let components = URLComponents(string: remoteURL), let scheme = components.scheme?.lowercased(),
           remoteURL.contains("://") {
            guard let host = components.host, !host.isEmpty else { return nil }
            switch scheme {
            case "https", "http":
                // Keep a port: a self-hosted service may serve its pages there.
                let port = components.port.map { ":\($0)" } ?? ""
                return (scheme, host + port, components.path)
            case "ssh", "git", "git+ssh", "ssh+git":
                // The SSH port is not the web server's.
                return ("https", host, components.path)
            default:
                return nil
            }
        }
        // `[user@]host:path`, with nothing that makes it a local path.
        guard let colon = remoteURL.firstIndex(of: ":") else { return nil }
        let before = remoteURL[..<colon]
        guard !before.contains("/"), before.count > 1 else { return nil }
        let host = before.split(separator: "@").last.map(String.init) ?? String(before)
        return ("https", host, String(remoteURL[remoteURL.index(after: colon)...]))
    }

    private static func kind(of host: String) -> Kind {
        let host = host.lowercased()
        if host == "github.com" || host.hasPrefix("github.") { return .github }
        if host == "gitlab.com" || host.hasPrefix("gitlab.") { return .gitlab }
        if host == "bitbucket.org" || host.hasPrefix("bitbucket.") { return .bitbucket }
        if host.hasSuffix("sr.ht") { return .sourcehut }
        if ["codeberg.org", "gitea.com"].contains(host) || host.hasPrefix("gitea.") || host.hasPrefix("forgejo.") {
            return .gitea
        }
        return .other
    }

    /// Percent-encodes each path segment, keeping the slashes between them.
    private static func encode(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}

extension RepositoryModel {
    /// The hosted repository a remote, by name, belongs to.
    func hostedRepository(remote name: String) -> HostedRepository? {
        snapshot?.remotes.first { $0.name == name }?.url.flatMap(HostedRepository.init(remoteURL:))
    }

    /// A remote's page on its hosting service.
    func webURL(forRemote name: String) -> URL? {
        hostedRepository(remote: name)?.url
    }

    /// A remote branch's page, by the remote branch's full name.
    func webURL(forRemoteBranch id: String) -> URL? {
        let (remote, branch) = remoteParts(of: id)
        return hostedRepository(remote: remote)?.url(forBranch: branch)
    }

    /// The page that starts a pull request from a remote branch, by its
    /// full name, into the main branch when that is known.
    func pullRequestURL(forRemoteBranch id: String) -> URL? {
        let (remote, branch) = remoteParts(of: id)
        return hostedRepository(remote: remote)?.newPullRequestURL(forBranch: branch, into: pullRequestBase(on: remote))
    }

    /// The page that starts a pull request from a local branch: from the
    /// remote branch it tracks, which must exist.
    func pullRequestURL(forBranch id: String) -> URL? {
        guard let upstream = snapshot?.branches.first(where: { $0.id == id })?.upstream else { return nil }
        let remoteBranch = "refs/remotes/" + upstream.name
        guard snapshot?.remotes.flatMap(\.branches).contains(where: { $0.id == remoteBranch }) == true else { return nil }
        return pullRequestURL(forRemoteBranch: remoteBranch)
    }

    /// Why a branch's menu cannot start a pull request, for its help text,
    /// or `nil` when it can.
    func pullRequestUnavailableReason(forBranch id: String) -> String? {
        guard snapshot?.branches.first(where: { $0.id == id })?.upstream != nil else {
            return "Publish the branch first: a pull request is made from a branch on the remote."
        }
        return pullRequestURL(forBranch: id) == nil ? Self.unknownHostReason : nil
    }

    static let unknownHostReason = "Twig does not know how this remote’s hosting service makes pull requests."

    /// The main branch's name on a remote, as a pull request's target:
    /// `main` for both `refs/heads/main` and `refs/remotes/origin/main`.
    private func pullRequestBase(on remote: String) -> String? {
        guard let base = interface.review?.base else { return nil }
        if base.hasPrefix("refs/remotes/") {
            let (baseRemote, branch) = remoteParts(of: base)
            return baseRemote == remote ? branch : nil
        }
        return Self.displayName(ofReference: base)
    }

    /// A commit's page on the hosting service of the remote it most likely
    /// lives on: the current branch's upstream remote, `origin`, or the
    /// only remote. `nil` when there is none, or its host is unknown.
    ///
    /// For the history and commit views' "Open on Web".
    func webURL(forCommit id: OID) -> URL? {
        let candidates = [defaultRemoteName].compactMap { $0 } + remoteNames
        for name in candidates {
            if let url = hostedRepository(remote: name)?.url(forCommit: id) { return url }
        }
        return nil
    }
}
