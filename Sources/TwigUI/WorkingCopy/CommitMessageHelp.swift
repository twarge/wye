import Foundation
import Observation

/// How long a commit subject is, against the limits git's conventions set:
/// about 50 characters reads well in a one-line log, and past 72 it wraps
/// or is cut off in most places that show it.
enum SubjectLength: Hashable {
    case fine
    /// Past the soft limit: worth shortening.
    case long
    /// Past the hard limit.
    case tooLong

    /// A limit of 0 is switched off.
    static func classify(_ subject: String, soft: Int, hard: Int) -> SubjectLength {
        let count = subject.trimmingCharacters(in: .whitespaces).count
        if hard > 0, count > hard { return .tooLong }
        if soft > 0, count > soft { return .long }
        return .fine
    }
}

/// A commit message as the composer's two fields.
enum CommitMessageText {
    /// The first paragraph, on one line, and the rest. With
    /// `strippingComments`, lines starting with `#` are left out first, as
    /// git leaves them out of a message written from a template.
    static func split(_ message: String, strippingComments: Bool = false) -> (subject: String, details: String) {
        var text = message
        if strippingComments {
            text = message.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)
        let subject = parts.first.map {
            $0.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        } ?? ""
        let details = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (subject, details)
    }

    /// A one-line preview of a message for a menu.
    static func summary(_ message: String, limit: Int = 60) -> String {
        let subject = split(message).subject
        guard subject.count > limit else { return subject }
        return subject.prefix(limit - 1) + "…"
    }
}

/// A message to start a commit from, kept by the app for every repository.
struct CommitTemplate: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var text: String
}

/// The composer's settings: subject limits and the app's templates.
@MainActor
@Observable
final class CommitPreferences {
    static let shared = CommitPreferences()

    static let softLimitChoices = [0, 50, 60, 72]
    static let hardLimitChoices = [0, 72, 80, 100]

    private enum Key {
        static let softLimit = "commit.subjectSoftLimit"
        static let hardLimit = "commit.subjectHardLimit"
        static let templates = "commit.templates"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Where the subject's counter turns to a warning; 0 is off.
    var softLimit: Int {
        didSet { defaults.set(softLimit, forKey: Key.softLimit) }
    }

    /// Where it turns to a stronger one; 0 is off.
    var hardLimit: Int {
        didSet { defaults.set(hardLimit, forKey: Key.hardLimit) }
    }

    var templates: [CommitTemplate] {
        didSet {
            if let data = try? JSONEncoder().encode(templates) {
                defaults.set(data, forKey: Key.templates)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        softLimit = defaults.object(forKey: Key.softLimit) as? Int ?? 50
        hardLimit = defaults.object(forKey: Key.hardLimit) as? Int ?? 72
        templates = defaults.data(forKey: Key.templates)
            .flatMap { try? JSONDecoder().decode([CommitTemplate].self, from: $0) } ?? []
    }

    func classify(_ subject: String) -> SubjectLength {
        SubjectLength.classify(subject, soft: softLimit, hard: hardLimit)
    }
}
