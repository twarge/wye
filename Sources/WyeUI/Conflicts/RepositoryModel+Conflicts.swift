import GitKit

extension RepositoryModel {
    /// Writes a hand-resolved file and marks it resolved. Returns whether it
    /// was saved; a failure is shown like any other.
    func saveConflictResolution(of file: ConflictFile, text: String) async -> Bool {
        var saved = false
        await perform { repository in
            try await repository.saveResolution(of: file, text: text)
            saved = true
        }
        return saved
    }

    /// Takes one side whole, from the resolver. Returns whether it worked.
    func resolveConflictWhole(at path: String, using side: ConflictSide) async -> Bool {
        var resolved = false
        await perform { repository in
            try await repository.resolveConflict(at: path, using: side)
            resolved = true
        }
        return resolved
    }
}
