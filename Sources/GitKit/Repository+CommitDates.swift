import Clibgit2
import Foundation

extension Repository {
    /// When each commit was made, by committer date, as `git for-each-ref
    /// --sort=-committerdate` orders references. Commits that cannot be
    /// read are left out.
    public func commitDates(of ids: some Collection<OID>) -> [OID: Date] {
        var dates: [OID: Date] = [:]
        dates.reserveCapacity(ids.count)
        for id in ids where dates[id] == nil {
            guard let commit = try? lookupCommit(id) else { continue }
            dates[id] = Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))
            git_commit_free(commit)
        }
        return dates
    }
}
