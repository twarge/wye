import Clibgit2
import Foundation

/// Notes attached to commits, as `git notes` keeps them: one note per commit
/// in the notes reference, `refs/notes/commits` unless `core.notesRef` names
/// another.
extension Repository {
    /// A commit's note, as `git notes show` prints it, or `nil` when it has none.
    public func note(for id: OID) throws -> String? {
        var note: OpaquePointer?
        var oid = id.raw
        let code = git_note_read(&note, pointer, nil, &oid)
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try check(code)
        defer { git_note_free(note) }
        return git_note_message(note).map { String(cString: $0) }
    }

    /// Gives a commit a note, replacing any it had. Like `git notes add -f`,
    /// the text is kept with one line break at its end. Empty text removes
    /// the note.
    public func setNote(_ text: String, for id: OID) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeNote(for: id)
            return
        }
        let signature = try branchingSignature()
        defer { git_signature_free(signature) }
        var created = git_oid()
        var oid = id.raw
        try check(git_note_create(&created, pointer, nil, signature, signature, &oid, trimmed + "\n", 1))
    }

    /// Removes a commit's note. Does nothing when it has none.
    public func removeNote(for id: OID) throws {
        let signature = try branchingSignature()
        defer { git_signature_free(signature) }
        var oid = id.raw
        let code = git_note_remove(pointer, nil, signature, signature, &oid)
        if code == GIT_ENOTFOUND.rawValue { return }
        try check(code)
    }

    /// Every commit that has a note, for marking them in the history.
    public func notedCommits() throws -> Set<OID> {
        var iterator: OpaquePointer?
        let code = git_note_iterator_new(&iterator, pointer, nil)
        // No notes reference yet: nothing has a note.
        if code == GIT_ENOTFOUND.rawValue { return [] }
        try check(code)
        defer { git_note_iterator_free(iterator) }
        var noted: Set<OID> = []
        var note = git_oid()
        var annotated = git_oid()
        while true {
            let next = git_note_next(&note, &annotated, iterator)
            if next == GIT_ITEROVER.rawValue { break }
            try check(next)
            noted.insert(OID(annotated))
        }
        return noted
    }
}
