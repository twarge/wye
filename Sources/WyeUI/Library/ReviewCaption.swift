import Foundation
import GitKit
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The pure half of a Review caption: what the model is shown of a
/// repository's work, bounded, and its answer read back as one line.
enum ReviewCaption {
    static let instructions = """
        You describe work in progress in a git repository, for a list of repositories. You are given the files \
        that changed, the commits not yet pushed, and an excerpt of the changes. Reply with one short phrase, at \
        most 12 words, saying what the work is about, such as "Adds dark mode to the settings window" or "Fixes \
        the crash when the list is empty". Start with a verb. No preamble, no quotation marks, no counts of files \
        or lines. Describe only what you are shown.
        """

    /// At most this many file names go in.
    static let fileLimit = 30
    /// At most this many unpushed commits' subjects go in.
    static let commitLimit = 8
    /// The changes of at most this many files go in the excerpt…
    static let excerptFileLimit = 8
    /// …each no larger than this on disk…
    static let excerptFileSize = 256 * 1024
    /// …and all of it cut to this many characters.
    static let excerptBudget = 3000

    /// The files whose changes go in the excerpt: the first few still on
    /// disk and small enough to be text worth reading. `size` is a file's
    /// size in bytes, or `nil` when it is not a regular file.
    static func excerptPaths(of entries: [StatusEntry], size: (String) -> Int?) -> [String] {
        var paths: [String] = []
        for entry in entries where entry.submodule == nil && entry.change != .deleted {
            guard paths.count < excerptFileLimit else { break }
            guard let bytes = size(entry.path), bytes <= excerptFileSize else { continue }
            paths.append(entry.path)
        }
        return paths
    }

    /// Shortens a patch to the excerpt's budget, each file keeping a share.
    static func excerpt(of patch: String) -> String {
        String(CommitMessageDraft.condensed(patch, budget: excerptBudget).prefix(excerptBudget))
    }

    /// What the model reads: the branch, the changed files, the unpushed
    /// commits and the excerpt, each bounded. `nil` when there is nothing
    /// to describe.
    static func prompt(for review: RepositoryReview, excerpt: String) -> String? {
        guard !review.entries.isEmpty || !review.commits.isEmpty else { return nil }
        var lines = ["Describe the work in progress in this repository."]
        if let branch = review.branch {
            lines.append("Branch: \(branch)")
        }
        if !review.entries.isEmpty {
            lines.append("")
            lines.append("Changed files:")
            for entry in review.entries.prefix(fileLimit) {
                lines.append("- \(entry.path) (\(describe(entry)))")
            }
            if review.entries.count > fileLimit {
                lines.append("- and \(review.entries.count - fileLimit) more")
            }
        }
        if !review.commits.isEmpty {
            lines.append("")
            lines.append("Commits not yet pushed:")
            for commit in review.commits.prefix(commitLimit) {
                lines.append("- \(commit.summary.prefix(120))")
            }
        }
        let excerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !excerpt.isEmpty {
            lines.append("")
            lines.append("Excerpt of the changes:")
            lines.append(String(excerpt.prefix(excerptBudget)))
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ entry: StatusEntry) -> String {
        let change = switch entry.change {
        case .added, .untracked: "new"
        case .modified, .typeChanged: "modified"
        case .deleted: "deleted"
        case .renamed: entry.originalPath.map { "renamed from \($0)" } ?? "renamed"
        case .copied: "copied"
        case .conflicted: "conflicted"
        }
        return entry.staged != nil && entry.unstaged == nil ? change + ", staged" : change
    }

    /// The model's answer as one line, without the quotes, fences and
    /// labels it sometimes adds; `nil` when nothing is left.
    static func parse(_ response: String) -> String? {
        let lines = response.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        guard var line = lines.first else { return nil }
        for label in ["Summary:", "Caption:", "Description:"] where line.lowercased().hasPrefix(label.lowercased()) {
            line = line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'`*").union(.whitespaces))
        guard !line.isEmpty else { return nil }
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }
}

/// Captions for the Review's repositories, written by the system's on-device
/// model: nothing leaves the device. Each is kept, for as long as the app
/// runs, until its repository's changes change. Written one at a time, off
/// the main thread, and only for repositories the Review shows.
@MainActor
@Observable
final class ReviewCaptions {
    static let shared = ReviewCaptions()

    /// What a caption was written from: when this differs, the changes did.
    struct Key: Hashable, Sendable {
        var entries: [StatusEntry]
        var commits: [OID]
        var lastModified: Date?

        init(_ review: RepositoryReview) {
            entries = review.entries
            commits = review.commits.map(\.id)
            lastModified = review.lastModified
        }
    }

    private struct Written {
        var key: Key
        /// `nil` when the model could not say: none is shown, and none is
        /// asked for again until the changes change.
        var text: String?
    }

    private struct Job {
        var key: Key
        var task: Task<Void, Never>
        var token: UUID
    }

    private var written: [UUID: Written] = [:]
    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    /// The last caption asked for; each waits for the one before it.
    @ObservationIgnored private var tail: Task<Void, Never>?

    /// The caption to show: the last one written, even while a newer one is.
    func caption(for id: UUID) -> String? {
        written[id]?.text
    }

    /// Whether the on-device model can write captions now.
    nonisolated static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// Writes `review`'s caption unless one is kept for these changes,
    /// waiting its turn. One not yet begun is dropped when the row asking
    /// for it goes away; one being written is finished and kept.
    func describe(_ review: RepositoryReview, in library: RepositoryLibrary) async {
        let key = Key(review)
        guard Self.isAvailable, written[review.id]?.key != key else { return }
        guard let bookmark = library.bookmarks.first(where: { $0.id == review.id }) else { return }
        let task: Task<Void, Never>
        if let job = jobs[review.id], job.key == key, !job.task.isCancelled {
            task = job.task
        } else {
            jobs[review.id]?.task.cancel()
            let previous = tail
            let token = UUID()
            task = Task {
                await previous?.value
                if !Task.isCancelled {
                    await write(review, key: key, bookmark: bookmark, library: library)
                }
                if jobs[review.id]?.token == token { jobs[review.id] = nil }
            }
            tail = task
            jobs[review.id] = Job(key: key, task: task, token: token)
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Forgets repositories no longer listed.
    func retain(_ ids: Set<UUID>) {
        for id in written.keys where !ids.contains(id) { written[id] = nil }
        for (id, job) in jobs where !ids.contains(id) {
            job.task.cancel()
            jobs[id] = nil
        }
    }

    private func write(
        _ review: RepositoryReview, key: Key, bookmark: RepositoryBookmark, library: RepositoryLibrary
    ) async {
        guard let access = try? library.access(to: bookmark) else { return }
        let url = access.url
        let prompt = await Task.detached(priority: .utility) {
            await Self.prompt(for: review, at: url)
        }.value
        // Held until the read is done: the folder is only open while it is.
        withExtendedLifetime(access) {}
        guard let prompt else {
            written[review.id] = Written(key: key, text: nil)
            return
        }
        // Its own task, so a row scrolled away does not stop it halfway.
        let text = await Task.detached(priority: .utility) {
            await Self.respond(to: prompt)
        }.value
        written[review.id] = Written(key: key, text: text)
    }

    private nonisolated static func prompt(for review: RepositoryReview, at url: URL) async -> String? {
        let paths = ReviewCaption.excerptPaths(of: review.entries) { path in
            let values = try? url.appending(path: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true ? values?.fileSize : nil
        }
        var excerpt = ""
        if !paths.isEmpty, let repository = try? Repository(at: url),
           let patch = try? await repository.workingCopyPatch(paths: paths) {
            excerpt = ReviewCaption.excerpt(of: patch)
        }
        return ReviewCaption.prompt(for: review, excerpt: excerpt)
    }

    private nonisolated static func respond(to prompt: String) async -> String? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: ReviewCaption.instructions)
        let response = try? await session.respond(
            to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 60)
        )
        return response.flatMap { ReviewCaption.parse($0.content) }
        #else
        return nil
        #endif
    }
}
