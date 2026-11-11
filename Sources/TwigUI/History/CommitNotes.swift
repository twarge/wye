import GitKit
import Observation
import SwiftUI

/// Notes on commits, kept by git in `refs/notes/commits`: which commits have
/// one, for the history's mark, and the note being written or removed.
@MainActor
@Observable
final class CommitNotes {
    /// A note being written for a commit.
    struct Draft: Identifiable {
        let commit: OID
        var text: String
        /// Whether the commit had a note already.
        let isEditing: Bool

        var id: OID { commit }
    }

    /// Every commit that has a note.
    private(set) var noted: Set<OID> = []
    /// Counts reloads, so a note on screen is read again after an edit.
    private(set) var generation = 0
    var draft: Draft?
    /// The commit whose note waits for confirmation to be removed.
    var removal: OID?

    private let repository: Repository

    init(repository: Repository) {
        self.repository = repository
    }

    func hasNote(_ commit: OID) -> Bool {
        noted.contains(commit)
    }

    /// Reads which commits have notes again.
    func reload() async {
        noted = (try? await repository.notedCommits()) ?? []
        generation += 1
    }

    /// Opens the editor on a commit's note, or on a new one.
    func edit(_ commit: OID, in model: RepositoryModel) async {
        do {
            let text = try await repository.note(for: commit)
            draft = Draft(commit: commit, text: text?.trimmingCharacters(in: .newlines) ?? "", isEditing: text != nil)
        } catch {
            model.error = PresentedError(error)
        }
    }

    func save(_ draft: Draft, in model: RepositoryModel) async {
        await model.perform { try await $0.setNote(draft.text, for: draft.commit) }
        await reload()
    }

    func remove(_ commit: OID, in model: RepositoryModel) async {
        await model.perform { try await $0.removeNote(for: commit) }
        await reload()
    }
}

/// The note items of a commit's menu.
struct CommitNoteMenuItems: View {
    var model: RepositoryModel
    var commit: Commit

    var body: some View {
        let notes = model.history.notes
        Section {
            if notes.hasNote(commit.id) {
                Button("Edit Note…", systemImage: "note.text") {
                    Task { await notes.edit(commit.id, in: model) }
                }
                Button("Remove Note…", systemImage: "note.text.badge.minus") {
                    notes.removal = commit.id
                }
            } else {
                Button("Add Note…", systemImage: "note.text.badge.plus") {
                    Task { await notes.edit(commit.id, in: model) }
                }
                .help("Attach a note to this commit without changing it, as git notes does")
            }
        }
    }
}

extension View {
    /// Presents the note editor and the question before a note is removed.
    func commitNotePresenters(_ model: RepositoryModel) -> some View {
        modifier(CommitNotePresenters(model: model, notes: model.history.notes))
    }
}

private struct CommitNotePresenters: ViewModifier {
    var model: RepositoryModel
    @Bindable var notes: CommitNotes

    func body(content: Content) -> some View {
        content
            .sheet(item: $notes.draft) { draft in
                NoteEditor(draft: draft) { notes.draft = nil } save: { edited in
                    notes.draft = nil
                    Task { await notes.save(edited, in: model) }
                }
            }
            .confirmationDialog(
                "Remove the note on \(notes.removal?.abbreviated() ?? "")?",
                isPresented: Binding { notes.removal != nil } set: { if !$0 { notes.removal = nil } },
                titleVisibility: .visible,
                presenting: notes.removal
            ) { commit in
                Button("Remove Note", role: .destructive) {
                    Task { await notes.remove(commit, in: model) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The note’s text is lost. The commit itself does not change.")
            }
    }
}

private struct NoteEditor: View {
    @State var draft: CommitNotes.Draft
    var cancel: () -> Void
    var save: (CommitNotes.Draft) -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft.text)
                .font(.body)
                .padding(8)
                .frame(minWidth: 380, minHeight: 200)
                .navigationTitle(draft.isEditing ? "Edit Note" : "Add Note")
                .navigationSubtitle(draft.commit.abbreviated())
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel, action: cancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save(draft) }
                            .disabled(!draft.isEditing && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

/// A commit's note under its message in the commit detail, when it has one.
struct CommitNoteSection: View {
    var model: RepositoryModel
    var commit: Commit

    @State private var note: (commit: OID, text: String)?

    var body: some View {
        let notes = model.history.notes
        Group {
            if let note, note.commit == commit.id {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Note", systemImage: "note.text")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit") {
                            Task { await notes.edit(commit.id, in: model) }
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                    }
                    Text(model.messageLinker.attributed(note.text))
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        // Again whenever a note is added, changed or removed anywhere.
        .task(id: NoteKey(commit: commit.id, noted: notes.hasNote(commit.id), generation: notes.generation)) {
            guard notes.hasNote(commit.id) else {
                note = nil
                return
            }
            let text = try? await model.repository.note(for: commit.id)
            note = text.map { (commit.id, $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    private struct NoteKey: Hashable {
        var commit: OID
        var noted: Bool
        var generation: Int
    }
}
