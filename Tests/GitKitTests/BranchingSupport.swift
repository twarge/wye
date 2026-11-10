import Foundation
import GitKit

extension Fixture {
    /// Two fixtures built the same way. git's commits carry the fixture's
    /// fixed dates, so both get the same object names: one can be changed
    /// with GitKit and the other with git, and the results compared.
    static func twins(_ build: (Fixture) throws -> Void) throws -> (ours: Fixture, git: Fixture) {
        let ours = try Fixture()
        let git = try Fixture()
        try build(ours)
        try build(git)
        return (ours, git)
    }

    func textOfFile(_ path: String) throws -> String {
        try String(contentsOf: url.appending(path: path), encoding: .utf8)
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: path).path)
    }

    /// `git log` in one format, a line per commit, first parents only unless
    /// asked otherwise.
    func logFormat(_ format: String, _ revision: String = "HEAD") throws -> [String] {
        try git("log", "--format=\(format)", revision).split(separator: "\n").map(String.init)
    }

    /// Each commit's tree, author and message, which come out the same
    /// whoever makes the commits, unlike their names and commit dates.
    func contentLog(_ revision: String = "HEAD") throws -> [String] {
        try logFormat("%T %an <%ae> %ad | %s", revision)
    }

    /// How many parents each commit has, newest first.
    func parentCounts(_ revision: String = "HEAD") throws -> [Int] {
        // The hash leads each line, so a root commit's line is not empty.
        try logFormat("%H %P", revision).map { $0.split(separator: " ").count - 1 }
    }
}
