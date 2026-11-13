import Foundation

/// One line of an interactive rebase's plan: a commit, and what to do with it.
public struct RebaseStep: Identifiable, Hashable, Sendable {
    public enum Action: String, Hashable, Sendable, CaseIterable {
        /// Replay the commit as it is.
        case pick
        /// Replay it with `message` as its message.
        case reword
        /// Meld its changes into the commit before, combining the messages.
        case squash
        /// Meld its changes into the commit before, keeping that one's message.
        case fixup
        /// Meld its changes into the commit before, taking this one's
        /// message in its place: git's `fixup -C`, which autosquash gives to
        /// `amend!` commits.
        case fixupWithMessage
        /// Leave the commit out.
        case drop

        /// Whether the step joins the commit made before it rather than
        /// making its own.
        public var meldsIntoPrevious: Bool {
            self == .squash || self == .fixup || self == .fixupWithMessage
        }

        /// The word git's todo list uses.
        public var todoWord: String {
            switch self {
            case .pick: "pick"
            case .reword: "reword"
            case .squash: "squash"
            case .fixup: "fixup"
            case .fixupWithMessage: "fixup -C"
            case .drop: "drop"
            }
        }
    }

    public var commit: OID
    public var action: Action
    /// For a reword, the new message. For the last squash or fixup of a run,
    /// the combined commit's message in place of the one git would make.
    public var message: String?
    /// For a pick or reword, an author in place of the commit's own.
    public var author: Signature?

    public var id: OID { commit }

    public init(commit: OID, action: Action = .pick, message: String? = nil, author: Signature? = nil) {
        self.commit = commit
        self.action = action
        self.message = message
        self.author = author
    }
}

/// A commit offered for an interactive rebase, with its whole message, which
/// squashing combines.
public struct RebaseCandidate: Identifiable, Hashable, Sendable {
    public let commit: Commit
    /// The message exactly as stored.
    public let message: String

    public var id: OID { commit.id }

    public init(commit: Commit, message: String) {
        self.commit = commit
        self.message = message
    }
}

/// What an interactive rebase from a commit would replay.
public struct RebaseTodo: Hashable, Sendable {
    /// Where the replayed commits go: the chosen commit's parent, or `nil`
    /// when the chosen commit is the first, so the new history starts afresh.
    public let onto: OID?
    /// Oldest first, as git's todo list has them. Merge commits are left out.
    public let candidates: [RebaseCandidate]
    /// How many merge commits the range has, which the rebase leaves out and
    /// so flattens.
    public let skippedMerges: Int
    /// The plan with `fixup!`, `squash!` and `amend!` commits moved after
    /// the commits they name and marked, as `--autosquash` does; `nil` when
    /// there are none.
    public let autosquashed: [RebaseStep]?
    /// Whether `onto` is outside the commits' own history, as when they move
    /// onto another branch: the plan changes the branch even left as it is.
    public let changesBase: Bool

    public init(
        onto: OID?, candidates: [RebaseCandidate], skippedMerges: Int, autosquashed: [RebaseStep]?,
        changesBase: Bool = false
    ) {
        self.onto = onto
        self.candidates = candidates
        self.skippedMerges = skippedMerges
        self.autosquashed = autosquashed
        self.changesBase = changesBase
    }

    /// Every commit picked, in order.
    public var plainSteps: [RebaseStep] {
        candidates.map { RebaseStep(commit: $0.id) }
    }
}

/// Builds the message of a commit that others are squashed or fixed up
/// into, exactly as git's sequencer does, so the result matches
/// `git rebase -i` left with its proposed message.
public struct SquashMessage: Hashable, Sendable, Codable {
    /// The messages shown so far, which git would offer for editing.
    private var visible: [String] = []
    /// The message to use as it is when no squash has been seen: the first
    /// commit's, or that of a `fixup -C`.
    private var verbatim: String?
    private var seenSquash = false
    private var count = 0

    public init() {}

    /// Whether nothing has been added yet.
    public var isEmpty: Bool { count == 0 }

    /// Adds a squash or fixup of a commit whose message is `message` to the
    /// commit whose message is `first`, which is read only for the first.
    public mutating func add(_ action: RebaseStep.Action, message: String, first: () -> String) {
        if count == 0 {
            let head = first()
            // A `fixup -C` drops the first message; anything else shows it.
            if action != .fixupWithMessage { visible.append(head) }
            if action == .fixup { verbatim = head }
        } else if action == .fixupWithMessage && !seenSquash {
            // With only fixups before, a `fixup -C` replaces everything so far.
            visible = []
        }
        switch action {
        case .squash, .fixupWithMessage:
            let hidesSubject = message.hasPrefix("amend!")
                || ((action == .squash || seenSquash) && (message.hasPrefix("squash!") || message.hasPrefix("fixup!")))
            let shown = hidesSubject ? Self.droppingSubject(of: message) : message
            visible.append(shown)
            if action == .squash {
                seenSquash = true
                verbatim = nil
            } else if !seenSquash {
                verbatim = Self.droppingLeadingBlankLines(of: shown)
            }
        default:
            break
        }
        count += 1
    }

    /// The combined message: the first commit's or a `fixup -C`'s as it is
    /// when nothing was squashed, otherwise the messages git would propose,
    /// cleaned up as committing them unedited does.
    public var message: String {
        if !seenSquash, let verbatim { return verbatim }
        return Self.cleanedUp(visible.joined(separator: "\n\n"))
    }

    /// Whether git would open the message for editing: something was squashed.
    public var isEdited: Bool { seenSquash }

    /// The combined message of a run of steps: a commit followed by the
    /// squashes and fixups melded into it.
    public static func combined(first: String, followers: [(action: RebaseStep.Action, message: String)]) -> String {
        var builder = SquashMessage()
        for follower in followers {
            builder.add(follower.action, message: follower.message) { first }
        }
        return builder.isEmpty ? first : builder.message
    }

    /// The message without its subject paragraph, as git comments it out.
    static func droppingSubject(of message: String) -> String {
        var lines = message.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let line = lines.first, !line.allSatisfy(\.isWhitespace) {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    static func droppingLeadingBlankLines(of text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while lines.count > 1, let line = lines.first, line.allSatisfy(\.isWhitespace) {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    /// git's clean-up of a message it offered for editing: comment lines
    /// and trailing spaces go, runs of blank lines become one, and blank
    /// lines at either end are dropped.
    public static func cleanedUp(_ text: String) -> String {
        var lines: [Substring] = []
        var pendingBlank = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") { continue }
            let trimmed = line.reversed().drop { $0.isWhitespace }.reversed()
            if trimmed.isEmpty {
                pendingBlank = !lines.isEmpty
                continue
            }
            if pendingBlank { lines.append("") }
            pendingBlank = false
            lines.append(Substring(trimmed))
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

extension RebaseTodo {
    /// Reorders and marks steps as `git rebase -i --autosquash` does: a
    /// commit whose subject starts `fixup!`, `squash!` or `amend!` goes after
    /// the commit its subject names, by that commit's subject, its hash or
    /// the start of its subject, and is marked fixup, squash or fixup with
    /// message. Returns `nil` when nothing moves or changes.
    ///
    /// `resolve` reads a commit name, for subjects that name a hash.
    static func autosquash(_ candidates: [RebaseCandidate], resolve: (String) -> OID?) -> [RebaseStep]? {
        var steps = candidates.map { RebaseStep(commit: $0.id) }
        let count = steps.count
        var next = Array(repeating: -1, count: count)
        var tail = Array(repeating: -1, count: count)
        var subjects: [String?] = Array(repeating: nil, count: count)
        var bySubject: [String: Int] = [:]
        let positions = Dictionary(candidates.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rearranged = false

        for index in 0..<count {
            let subject = Self.subjectLine(of: candidates[index].message)
            subjects[index] = subject
            var target: Int?
            if var rest = Self.skippingFixupPrefix(subject) {
                while true {
                    rest = String(rest.drop { $0.isWhitespace })
                    guard let shorter = Self.skippingFixupPrefix(rest) else { break }
                    rest = shorter
                }
                if let found = bySubject[rest] {
                    target = found
                } else if !rest.contains(" "), let id = resolve(rest), let found = positions[id] {
                    target = found
                } else {
                    target = (0..<index).first { subjects[$0]?.hasPrefix(rest) == true }
                }
                if target == index { target = nil }
            }
            if let target {
                rearranged = true
                steps[index].action = if subject.hasPrefix("fixup!") {
                    .fixup
                } else if subject.hasPrefix("amend!") {
                    .fixupWithMessage
                } else {
                    .squash
                }
                // Append to the target's run of fixups, keeping their order.
                let after = tail[target] < 0 ? target : tail[target]
                next[index] = next[after]
                next[after] = index
                tail[target] = index
            } else if bySubject[subject] == nil {
                bySubject[subject] = index
            }
        }
        guard rearranged else { return nil }

        var ordered: [RebaseStep] = []
        for index in 0..<count where !steps[index].action.meldsIntoPrevious {
            var current = index
            while current >= 0 {
                ordered.append(steps[current])
                current = next[current]
            }
        }
        // A fixup whose chain never reaches a picked commit (named by a
        // hash later in the list that is itself a fixup) is kept, as git does.
        let placed = Set(ordered.map(\.commit))
        ordered += steps.filter { !placed.contains($0.commit) }
        return ordered
    }

    /// The subject as git formats it: the first paragraph's lines, joined by spaces.
    static func subjectLine(of message: String) -> String {
        var lines: [Substring] = []
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.reversed().drop { $0.isWhitespace }.reversed()
            if trimmed.isEmpty {
                if lines.isEmpty { continue }
                break
            }
            lines.append(Substring(trimmed))
        }
        return lines.joined(separator: " ")
    }

    private static func skippingFixupPrefix(_ text: String) -> String? {
        for prefix in ["fixup!", "amend!", "squash!"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return nil
    }
}
