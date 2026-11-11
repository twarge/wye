import Foundation
import GitKit
import Testing
@testable import WyeUI

/// The push-tags settings, the New Tag sheet's remembered choice, and how
/// pushing a new tag to several remotes goes and is told.
@MainActor
@Suite struct TagPushPreferenceTests {
    private func freshDefaults() -> UserDefaults {
        let name = "WyeUITests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func bothAreOnOnAFreshInstall() {
        let defaults = freshDefaults()
        #expect(PushPreferences.pushesAllTags(defaults: defaults))
        #expect(PushPreferences.pushesNewTags(defaults: defaults))
        #expect(RepositoryPreferences.resolvedPushesAllTags(for: UUID(), defaults: defaults))
    }

    @Test func theNewTagChoiceIsRemembered() {
        let defaults = freshDefaults()
        PushPreferences.setPushesNewTags(false, defaults: defaults)
        #expect(!PushPreferences.pushesNewTags(defaults: defaults))
        PushPreferences.setPushesNewTags(true, defaults: defaults)
        #expect(PushPreferences.pushesNewTags(defaults: defaults))
    }

    @Test func aRepositoryCanSetItsOwn() {
        let defaults = freshDefaults()
        let id = UUID(), otherID = UUID()
        #expect(RepositoryPreferences.pushesAllTags(for: id, defaults: defaults) == nil)

        RepositoryPreferences.setPushesAllTags(false, for: id, defaults: defaults)
        #expect(!RepositoryPreferences.resolvedPushesAllTags(for: id, defaults: defaults))
        #expect(RepositoryPreferences.resolvedPushesAllTags(for: otherID, defaults: defaults))

        // Turned off in the app, a repository can still turn it on.
        defaults.set(false, forKey: PushPreferences.pushesAllTagsKey)
        RepositoryPreferences.setPushesAllTags(true, for: id, defaults: defaults)
        #expect(RepositoryPreferences.resolvedPushesAllTags(for: id, defaults: defaults))
        #expect(!RepositoryPreferences.resolvedPushesAllTags(for: otherID, defaults: defaults))

        // Back to following the app.
        RepositoryPreferences.setPushesAllTags(nil, for: id, defaults: defaults)
        #expect(RepositoryPreferences.pushesAllTags(for: id, defaults: defaults) == nil)
        #expect(!RepositoryPreferences.resolvedPushesAllTags(for: id, defaults: defaults))
    }

    @Test func theToggleNamesTheOnlyRemote() {
        #expect(RepositoryModel.newTagPushTitle(remotes: []) == nil)
        #expect(RepositoryModel.newTagPushTitle(remotes: ["origin"]) == "Push to “origin”")
        #expect(RepositoryModel.newTagPushTitle(remotes: ["origin", "backup"]) == "Push to All Remotes")
    }

    @Test func aFailingRemoteDoesNotStopTheOthers() async {
        struct Unreachable: LocalizedError {
            var errorDescription: String? { "Could not reach it." }
        }
        var tried: [String] = []
        let outcome = await RepositoryModel.pushTag(to: ["origin", "gone", "backup"]) { remote in
            tried.append(remote)
            return remote == "gone" ? Unreachable() : nil
        }
        #expect(tried == ["origin", "gone", "backup"])
        #expect(outcome.pushed == ["origin", "backup"])
        #expect(outcome.failed.map(\.remote) == ["gone"])

        let message = RepositoryModel.newTagPushFailureMessage(tag: "v1", outcome)
        #expect(message?.contains("pushed to “origin” and “backup”") == true)
        #expect(message?.contains("wasn’t pushed to “gone”: Could not reach it.") == true)
    }

    @Test func cancellingStopsAndSaysWhatWasLeft() async {
        let outcome = await RepositoryModel.pushTag(to: ["origin", "backup", "third"]) { remote in
            remote == "backup" ? CancellationError() : nil
        }
        #expect(outcome.pushed == ["origin"])
        #expect(outcome.skipped == ["backup", "third"])
        #expect(RepositoryModel.newTagPushFailureMessage(tag: "v1", outcome)?.contains("cancelled before") == true)
        // Everything went: nothing to say.
        #expect(RepositoryModel.newTagPushFailureMessage(tag: "v1", NewTagPushOutcome(pushed: ["origin"])) == nil)
    }

    @Test func aRealPushGoesOnPastAMissingRemote() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WyeUITests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try Repository.create(at: folder.appending(path: "repository"))
        try "[user]\n\tname = Test\n\temail = test@example.com\n".write(
            to: folder.appending(path: "repository/.git/config"), atomically: true, encoding: .utf8
        )
        try "one\n".write(to: folder.appending(path: "repository/a.txt"), atomically: true, encoding: .utf8)
        try await repository.stage(["a.txt"])
        let commit = try await repository.commit(message: "One")
        let tag = try await repository.createTag(named: "v1", at: commit, message: "Version one")
        // libgit2 pushes locally only to a bare repository, and GitKit makes
        // none, so the good remote's git folder is marked bare.
        let good = try Repository.create(at: folder.appending(path: "good"))
        let goodConfig = folder.appending(path: "good/.git/config")
        let config = try String(contentsOf: goodConfig, encoding: .utf8)
        try config.replacingOccurrences(of: "bare = false", with: "bare = true")
            .write(to: goodConfig, atomically: true, encoding: .utf8)
        try await repository.addRemote(named: "gone", url: folder.appending(path: "missing").path)
        try await repository.addRemote(named: "good", url: folder.appending(path: "good/.git").path)

        let outcome = await RepositoryModel.pushTag(to: ["gone", "good"]) { remote in
            do {
                try await repository.pushTags([tag], to: remote)
                return nil
            } catch {
                return error
            }
        }
        #expect(outcome.pushed == ["good"])
        #expect(outcome.failed.map(\.remote) == ["gone"])
        #expect(try await good.snapshot().tags.map(\.name) == ["v1"])
    }

    @Test func undoingAPushedTagSaysTheRemotesKeepIt() {
        let message = RepositoryModel.pushedTagUndoMessage(tag: "v1", remotes: ["origin"])
        #expect(message.contains("“v1” was pushed to “origin”"))
        #expect(message.contains("the remote keeps it"))
        #expect(RepositoryModel.pushedTagUndoMessage(tag: "v1", remotes: ["a", "b"]).contains("the remotes keep it"))
    }

    @Test func rejectedTagsAreTold() {
        let clean = PushResult(
            remote: "origin", reference: "refs/heads/main", setUpstream: false, tags: PushedTags(pushed: ["v2"], rejected: [])
        )
        #expect(RepositoryModel.rejectedTagsMessage(clean) == nil)
        let rejected = PushResult(
            remote: "origin", reference: "refs/heads/main", setUpstream: false,
            tags: PushedTags(pushed: [], rejected: [.init(tag: "v1", reason: PushedTags.elsewhereReason)])
        )
        let message = RepositoryModel.rejectedTagsMessage(rejected)
        #expect(message?.hasPrefix("“main” was pushed to “origin”, but this tag wasn’t") == true)
        #expect(message?.contains("“v1”: \(PushedTags.elsewhereReason)") == true)
    }
}
