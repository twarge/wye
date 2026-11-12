import Foundation
import FoundationModels
import GitKit

/// The pure half of drafting a commit message: fitting a patch into what
/// the model can read, and reading its answer back as a subject and a body.
enum CommitMessageDraft {
    static let instructions = """
        You write git commit messages. You are given a patch. Reply with the commit message and nothing else: \
        no preamble, no quotation marks, no code fences.
        The first line is the subject: imperative mood, as in "Fix crash when the list is empty", at most 60 \
        characters, no full stop at the end. Then, only if the change needs explaining, an empty line and a \
        short body in plain sentences saying what changed and why. Describe only what the patch shows.
        """

    /// Characters of patch for each token of the model's context, roughly:
    /// code runs to fewer characters a token than prose does.
    static let charactersPerToken = 2.5

    /// How much patch fits a context of `contextSize` tokens, leaving room
    /// for the instructions and the answer.
    static func budget(forContextSize contextSize: Int) -> Int {
        let tokens = max(contextSize - 900, 600)
        return Int(Double(tokens) * charactersPerToken)
    }

    /// Shortens a patch to `budget` characters, fairly: every file keeps
    /// its header and as much of its changes as its share allows, rather
    /// than the first files crowding out the rest. Binary contents go.
    static func condensed(_ patch: String, budget: Int) -> String {
        var files: [[Substring]] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") || files.isEmpty {
                files.append([])
            }
            files[files.count - 1].append(line)
        }
        files = files.map(withoutBinary)
        let total = files.reduce(0) { $0 + size(of: $1) }
        guard total > budget, !files.isEmpty else {
            return files.map { $0.joined(separator: "\n") }.joined(separator: "\n")
        }
        let share = max(budget / files.count, 200)
        return files.map { lines in
            guard size(of: lines) > share else { return lines.joined(separator: "\n") }
            var kept: [Substring] = []
            var used = 0
            for line in lines {
                guard used + line.count + 1 <= share else { break }
                kept.append(line)
                used += line.count + 1
            }
            kept.append("[… the rest of this file's changes are left out]")
            return kept.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func size(of lines: [Substring]) -> Int {
        lines.reduce(0) { $0 + $1.count + 1 }
    }

    /// A binary file's patch is its bytes as text, which says nothing.
    private static func withoutBinary(_ lines: [Substring]) -> [Substring] {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("GIT binary patch") }) else { return lines }
        return Array(lines[..<start]) + ["[binary file changed]"]
    }

    static func prompt(patch: String, budget: Int) -> String {
        "Write the commit message for this patch.\n\n" + condensed(patch, budget: budget)
    }

    /// Splits the model's answer into subject and body, forgiving the
    /// fences, quotes and labels it sometimes adds anyway.
    static func parse(_ response: String) -> (subject: String, body: String) {
        var lines = response.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard var subject = lines.first?.trimmingCharacters(in: .whitespaces) else { return ("", "") }
        for label in ["Subject:", "subject:", "Commit message:"] where subject.hasPrefix(label) {
            subject = subject.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
        }
        subject = subject.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”`*"))
        if subject.hasSuffix("."), !subject.hasSuffix("..") { subject.removeLast() }
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (subject, body)
    }
}

/// Drafts a commit message from the changes about to be committed, with the
/// system's on-device model: nothing leaves the device.
enum CommitMessageDrafter {
    enum Failure: LocalizedError {
        case nothingToDescribe
        case unavailable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .nothingToDescribe: "There are no changes to describe."
            case .unavailable(let reason): reason
            case .empty: "The model gave no message. Try again, or stage fewer changes at once."
            }
        }
    }

    /// Why a draft cannot be offered here, or `nil` when it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This device does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in Settings to draft messages."
        case .unavailable(.modelNotReady):
            "The on-device model is still downloading. Try again in a while."
        case .unavailable:
            "The on-device model is not available."
        }
    }

    /// Whether to show the command at all: not on a device that can never run it.
    static var isSupported: Bool {
        if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability { return false }
        return true
    }

    /// Describes what is staged, or every change when nothing is.
    static func draft(for repository: Repository) async throws -> (subject: String, body: String) {
        if let reason = unavailableReason { throw Failure.unavailable(reason) }
        var patch = try await repository.workingCopyPatch(stagedOnly: true)
        if patch.isEmpty {
            patch = try await repository.workingCopyPatch()
        }
        guard !patch.isEmpty else { throw Failure.nothingToDescribe }

        let budget = CommitMessageDraft.budget(forContextSize: SystemLanguageModel.default.contextSize)
        do {
            return try await respond(to: patch, budget: budget)
        } catch let failure as Failure {
            throw failure
        } catch {
            // Most often the patch was still too long for the context: the
            // estimate is by characters, and the model counts tokens.
            return try await respond(to: patch, budget: budget / 2)
        }
    }

    private static func respond(to patch: String, budget: Int) async throws -> (subject: String, body: String) {
        let session = LanguageModelSession(instructions: CommitMessageDraft.instructions)
        let response = try await session.respond(
            to: CommitMessageDraft.prompt(patch: patch, budget: budget),
            options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 300)
        )
        let message = CommitMessageDraft.parse(response.content)
        guard !message.subject.isEmpty else { throw Failure.empty }
        return message
    }
}
