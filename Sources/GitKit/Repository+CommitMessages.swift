import Clibgit2
import Foundation

extension Repository {
    /// The messages of recent commits on the current branch, newest first,
    /// each once, for writing a new message from an old one. When an
    /// identity is configured, only commits it authored count.
    ///
    /// - Parameters:
    ///   - limit: How many messages to return at most.
    ///   - scanning: How many commits to look through at most, so a long
    ///     history by other people costs no more than this.
    public func recentCommitMessages(limit: Int = 20, scanning: Int = 500) throws -> [String] {
        guard limit > 0, let head = try headCommit() else { return [] }
        git_commit_free(head)
        let email = identity()?.email.lowercased()

        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, pointer))
        defer { git_revwalk_free(walk) }
        try check(git_revwalk_sorting(walk, GIT_SORT_TIME.rawValue))
        try check(git_revwalk_push_head(walk))

        var messages: [String] = []
        var seen: Set<String> = []
        var oid = git_oid()
        var scanned = 0
        while messages.count < limit, scanned < scanning, git_revwalk_next(&oid, walk) == 0 {
            scanned += 1
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, pointer, &oid))
            defer { git_commit_free(commit) }
            if let email, let author = git_commit_author(commit)?.pointee,
               author.email.map({ String(cString: $0).lowercased() }) != email {
                continue
            }
            let message = (git_commit_message(commit).map { String(cString: $0) } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty, seen.insert(message).inserted else { continue }
            messages.append(message)
        }
        return messages
    }

    /// What recent history offers for completing a commit message: the
    /// people who wrote it, most recent first, the issue numbers its
    /// messages mention, and the subjects of the commits a `fixup!` or
    /// `squash!` could name, newest first, each once.
    ///
    /// - Parameter scanning: How many commits reachable from `HEAD` to read.
    public func commitCompletionSources(scanning: Int = 300) throws -> CommitCompletionSources {
        var sources = CommitCompletionSources()
        guard let head = try headCommit() else { return sources }
        git_commit_free(head)
        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, pointer))
        defer { git_revwalk_free(walk) }
        try check(git_revwalk_sorting(walk, GIT_SORT_TIME.rawValue))
        try check(git_revwalk_push_head(walk))

        var people: Set<String> = []
        var issues: Set<String> = []
        var oid = git_oid()
        var scanned = 0
        while scanned < scanning, git_revwalk_next(&oid, walk) == 0 {
            scanned += 1
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, pointer, &oid))
            defer { git_commit_free(commit) }
            for signature in [git_commit_author(commit), git_commit_committer(commit)] {
                guard let signature = signature?.pointee,
                      let name = signature.name.map({ String(cString: $0) }),
                      let email = signature.email.map({ String(cString: $0) }),
                      !name.isEmpty, people.insert(email.lowercased()).inserted else { continue }
                sources.people.append(GitIdentity(name: name, email: email))
            }
            let message = git_commit_message(commit).map { String(cString: $0) } ?? ""
            let summary = git_commit_summary(commit).map { String(cString: $0) } ?? ""
            if !summary.hasPrefix("fixup! "), !summary.hasPrefix("squash! ") {
                sources.subjects.append(CommitCompletionSources.Subject(id: OID(oid), summary: summary))
            }
            for issue in Self.issueReferences(in: message) where issues.insert(issue).inserted {
                sources.issues.append(issue)
            }
        }
        return sources
    }

    /// `#123` and `GH-123` style references in a message, as `#123`.
    static func issueReferences(in message: String) -> [String] {
        var found: [String] = []
        var previous: Character = " "
        var index = message.startIndex
        while index < message.endIndex {
            let character = message[index]
            let after = message.index(after: index)
            if character == "#", !previous.isLetter, !previous.isNumber, previous != "&" {
                let digits = message[after...].prefix { $0.isASCII && $0.isNumber }
                if !digits.isEmpty { found.append("#" + digits) }
            }
            previous = character
            index = after
        }
        return found
    }

    /// The text of the file `commit.template` names, when it lies inside the
    /// working tree. A template elsewhere, such as in the home folder, is
    /// outside what the app may read, and is passed over.
    public func commitTemplate() throws -> String? {
        guard let workingDirectory = git_repository_workdir(pointer).map({ String(cString: $0) }) else {
            return nil
        }
        var configuration: OpaquePointer?
        try check(git_repository_config(&configuration, pointer))
        defer { git_config_free(configuration) }
        guard let setting = GitEnvironment.string(for: "commit.template", in: configuration),
              !setting.hasPrefix("~") else { return nil }

        let root = URL(filePath: workingDirectory, directoryHint: .isDirectory)
            .standardizedFileURL.resolvingSymlinksInPath()
        // git reads a relative path from where it runs, which for a
        // repository opened here is the top of the working tree.
        let file = (setting.hasPrefix("/") ? URL(filePath: setting) : root.appending(path: setting))
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath),
              let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What recent history offers for completing a commit message.
public struct CommitCompletionSources: Hashable, Sendable {
    /// A commit a `fixup!` or `squash!` can name by its subject.
    public struct Subject: Hashable, Sendable {
        public var id: OID
        public var summary: String

        public init(id: OID, summary: String) {
            self.id = id
            self.summary = summary
        }
    }

    /// Authors and committers, most recent first, each email once.
    public var people: [GitIdentity] = []
    /// Issue references such as `#123`, most recently mentioned first.
    public var issues: [String] = []
    public var subjects: [Subject] = []

    public init(people: [GitIdentity] = [], issues: [String] = [], subjects: [Subject] = []) {
        self.people = people
        self.issues = issues
        self.subjects = subjects
    }
}
