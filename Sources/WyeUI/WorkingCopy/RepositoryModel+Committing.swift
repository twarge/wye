import Foundation
import GitKit

extension WorkingCopyState {
    /// The selected files, for a list that selects several. Code that sets
    /// `selection` alone, to show one file, also makes it the only one
    /// selected here.
    var selectedSet: Set<String> {
        get {
            guard let selection else { return [] }
            return selectedPaths.contains(selection) ? selectedPaths : [selection]
        }
        set {
            selectedPaths = newValue
            if let selection, newValue.contains(selection) { return }
            selection = newValue.count == 1 ? newValue.first : newValue.sorted().first
        }
    }

    /// The selected files that have changes to stash, in the list's order.
    var selectedChangedPaths: [String] {
        let selected = selectedSet
        return entries.filter { selected.contains($0.path) && !$0.isConflicted }.map(\.path)
    }
}

extension RepositoryModel {
    // MARK: Author and signing

    /// The profile picked for the next commit, or this repository's.
    /// `nil` commits as the repository's configuration says.
    var commitProfile: AuthorProfile? {
        AuthorProfiles.shared.chosenProfile(
            forCommit: workingCopy.commitProfile, repository: interface.stored.authorProfile
        )
    }

    /// Who the composer's commit is by, when a profile says; otherwise the
    /// configured identity is used.
    var commitIdentity: GitIdentity? {
        commitProfile?.identity
    }

    /// The name the composer shows after "As".
    var composerIdentity: GitIdentity? {
        commitIdentity ?? workingCopy.identity
    }

    /// Whether and how the composer's commit is signed.
    var composerSigningPlan: SigningPlan {
        AuthorProfiles.shared.signingPlan(for: commitProfile, repositorySigns: interface.stored.signsCommits)
    }

    /// Signs the commits this repository makes as its own profile would:
    /// merges, rebases and cherry-picks as much as the composer's. A key that
    /// cannot be read leaves them unsigned; committing says why.
    func updateCommitSigning() {
        let profile = AuthorProfiles.shared.profile(id: interface.stored.authorProfile)
        let plan = AuthorProfiles.shared.signingPlan(for: profile, repositorySigns: interface.stored.signsCommits)
        repository.setCommitSigner(try? SigningKeys.signer(for: plan))
    }

    /// Commits or amends as the composer's profile, signed if it should be,
    /// then goes back to the repository's own profile.
    func commitFromComposer() async {
        do {
            repository.setCommitSigner(try SigningKeys.signer(for: composerSigningPlan))
        } catch {
            report(error)
            return
        }
        let wasCommitting = !workingCopy.isAmending
        await commitOrAmend()
        // The pick was for one commit; once it is made, the next is as before.
        if wasCommitting ? workingCopy.subject.isEmpty : !workingCopy.isAmending {
            workingCopy.commitProfile = nil
        }
        updateCommitSigning()
    }

    // MARK: Stashing part of the changes

    /// Stashes only the changes to some files, as `git stash push -- <paths>`.
    func saveStash(paths: [String], message: String, options: StashOptions) async {
        await perform(.stashSave(includingUntracked: options.contains(.includeUntracked))) {
            try await $0.saveStash(paths: paths, message: message, options: options)
        }
    }

    /// Stashes some of a file's unstaged lines and takes them out of it.
    func saveStash(lines: Set<Int>, of file: FileDiff, message: String) async {
        let options = DiffPreferences.shared.options
        await perform(.stashSave(includingUntracked: false)) {
            try await $0.saveStash(lines: lines, of: file, message: message, options: options)
        }
    }

    // MARK: Patches

    /// What to save as a patch.
    enum PatchScope {
        case all
        case staged
        case files([String])
    }

    /// Writes uncommitted changes as a patch and asks where to save it.
    func savePatch(_ scope: PatchScope) async {
        do {
            let text: String
            let fileName: String
            switch scope {
            case .all:
                text = try await repository.workingCopyPatch()
                fileName = "\(name)-changes.patch"
            case .staged:
                text = try await repository.workingCopyPatch(stagedOnly: true)
                fileName = "\(name)-staged.patch"
            case .files(let paths):
                text = try await repository.workingCopyPatch(paths: paths)
                fileName = paths.count == 1 ? "\(paths[0].splitPath.name).patch" : "\(name)-changes.patch"
            }
            guard !text.isEmpty else { throw EmptyPatchError() }
            history.requests.patchExport = PatchExport(document: PatchDocument(text: text), fileName: fileName)
        } catch {
            report(error)
        }
    }
}

/// There is nothing to write into a patch.
struct EmptyPatchError: LocalizedError {
    var errorDescription: String? { "There are no changes to save as a patch." }
}
