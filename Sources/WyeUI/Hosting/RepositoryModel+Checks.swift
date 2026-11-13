import Foundation
import GitKit

extension RepositoryModel {
    /// The repositories whose checks the history's marks stand for: each
    /// remote on a service whose checks Wye reads, with an account signed
    /// in to read them, once however many remotes name it.
    var checkSources: [CheckSource] {
        var seen: Set<String> = []
        return hostingTargets.compactMap { target in
            let key = target.hosted.key
            guard !seen.contains(key), let account = hostingAccount(for: target), let service = try? account.service(),
                  service.capabilities.checkBatchSize > 0 else { return nil }
            seen.insert(key)
            return CheckSource(
                key: key, remote: target.remote, kind: target.kind, path: target.path, hosted: target.hosted,
                accountID: account.id, service: service
            )
        }
    }
}

extension HostedRepository {
    /// The page of a commit's checks or pipelines, or `nil` where Wye
    /// does not read them.
    func url(forChecksOf id: OID) -> URL? {
        let path: String? = switch kind {
        case .github: "commit/\(id.hex)/checks"
        case .gitlab: "-/commit/\(id.hex)/pipelines"
        case .bitbucket, .gitea, .sourcehut, .other: nil
        }
        return path.flatMap { URL(string: url.absoluteString + "/" + $0) }
    }
}
