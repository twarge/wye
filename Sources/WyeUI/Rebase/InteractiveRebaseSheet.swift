import GitKit
import SwiftUI

/// Plans an interactive rebase: the commits from a commit to `HEAD`, or
/// those `HEAD` has that another commit lacks, oldest first as git's todo
/// list has them, each to pick, reword, squash, fix up or drop, in an
/// order changed by dragging or by Move Up and Move Down.
struct InteractiveRebaseSheet: View {
    var model: RepositoryModel
    var plan: InteractiveRebasePlan

    @Environment(\.dismiss) private var dismiss
    @State private var draft: InteractiveRebaseDraft?
    @State private var failure: String?
    @State private var selection: OID?
    @State private var editing: MessageEdit?
    /// The remote branch that already has the commits, if any.
    @State private var publishedOn: String?

    var body: some View {
        SheetStack("Interactive Rebase", placement: .above(inset: 16)) {
            Group {
                if let draft {
                    PlanList(draft: draft, selection: $selection) { row in
                        editing = MessageEdit(id: row.id, title: row.action == .reword ? "Reword" : "Squash Message",
                                              text: draft.message(for: row.id))
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { footer(draft) }
                } else if let failure {
                    ContentUnavailableView(failureTitle, systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar { toolbar }
        }
        .sheetMinimumSize(width: 620, height: 480)
        .task { await load() }
        .sheet(item: $editing) { edit in
            MessageEditorSheet(title: edit.title, text: edit.text) { message in
                draft?.setMessage(message, for: edit.id)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Rebase") { run() }
                .disabled(draft == nil || draft?.problem != nil || draft?.isUnchanged != false)
        }
        #if !os(macOS)
        ToolbarItemGroup(placement: .secondaryAction) {
            moveButtons
        }
        #endif
    }

    /// In the toolbar on iOS; a Mac sheet has no bar for them, so there
    /// they head the footer.
    @ViewBuilder
    private var moveButtons: some View {
        Button("Move Up", systemImage: "arrow.up") { moveSelection(by: -1) }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(!canMoveSelection(by: -1))
        Button("Move Down", systemImage: "arrow.down") { moveSelection(by: 1) }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!canMoveSelection(by: 1))
    }

    private func footer(_ draft: InteractiveRebaseDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            #if os(macOS)
            HStack {
                moveButtons
            }
            .buttonStyle(.borderless)
            #endif
            if draft.todo.autosquashed != nil {
                Toggle("Autosquash", isOn: Binding { draft.autosquash } set: { draft.autosquash = $0 })
                    .help("Move fixup!, squash! and amend! commits after the commits they name, and mark them")
            }
            if let problem = draft.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Text(explanation(draft))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func explanation(_ draft: InteractiveRebaseDraft) -> String {
        var parts = ["Oldest first. Commits are replayed from the top; drag or use Move Up and Move Down to reorder."]
        if case .onto(let base) = plan {
            parts.append(draft.todo.changesBase
                         ? "They move onto \(base.abbreviated()), which the branch does not have yet."
                         : "They are replayed onto \(base.abbreviated()).")
        }
        if draft.todo.skippedMerges > 0 {
            let count = draft.todo.skippedMerges
            parts.append("\(count) merge \(count == 1 ? "commit is" : "commits are") left out, so the history becomes a line.")
        }
        if let publishedOn {
            parts.append("Some of these commits are already on \(publishedOn): publishing the result needs a force push.")
        }
        parts.append("A conflict stops the rebase to resolve in the working copy; Abort returns everything to how it was, and Undo reverses a finished rebase.")
        return parts.joined(separator: " ")
    }

    private var failureTitle: LocalizedStringKey {
        switch plan {
        case .from: "Cannot Rebase from Here"
        case .onto: "Cannot Rebase onto Here"
        }
    }

    private func load() async {
        let repository = model.repository
        do {
            let todo = switch plan {
            case .from(let start): try await repository.interactiveRebaseTodo(from: start)
            case .onto(let base): try await repository.interactiveRebaseTodo(onto: base)
            }
            guard let oldest = todo.candidates.first else {
                failure = switch plan {
                case .from: "There are no commits to replay from here."
                case .onto: "The current branch has no commits that this one lacks."
                }
                return
            }
            draft = InteractiveRebaseDraft(todo: todo)
            let start = if case .from(let start) = plan { start } else { oldest.id }
            publishedOn = try? await repository.remoteBranch(containing: start)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func canMoveSelection(by delta: Int) -> Bool {
        guard let selection, let draft else { return false }
        return draft.canMove(selection, by: delta)
    }

    private func moveSelection(by delta: Int) {
        guard let selection else { return }
        withMotion { draft?.move(selection, by: delta) }
    }

    private func run() {
        guard let draft else { return }
        let onto = draft.todo.onto
        let steps = draft.steps
        dismiss()
        Task { await model.runInteractiveRebase(onto: onto, steps: steps) }
    }
}

/// A message being edited for a row.
private struct MessageEdit: Identifiable {
    let id: OID
    var title: String
    var text: String
}

/// The plan's rows, oldest first.
private struct PlanList: View {
    var draft: InteractiveRebaseDraft
    @Binding var selection: OID?
    var editMessage: (InteractiveRebaseDraft.Row) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(draft.rows) { row in
                PlanRow(draft: draft, row: row, editMessage: { editMessage(row) })
                    .tag(row.id)
                    .contextMenu { menu(for: row) }
                    .swipeActions(edge: .leading) {
                        Button("Move Up", systemImage: "arrow.up") { withMotion { draft.move(row.id, by: -1) } }
                            .disabled(!draft.canMove(row.id, by: -1))
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Move Down", systemImage: "arrow.down") { withMotion { draft.move(row.id, by: 1) } }
                            .disabled(!draft.canMove(row.id, by: 1))
                    }
            }
            .onMove { offsets, offset in draft.move(fromOffsets: offsets, toOffset: offset) }
        }
    }

    @ViewBuilder
    private func menu(for row: InteractiveRebaseDraft.Row) -> some View {
        Section {
            ForEach(RebaseStep.Action.allCases, id: \.self) { action in
                Button(action.title, systemImage: action.systemImage) { draft.setAction(action, for: row.id) }
            }
        }
        Section {
            Button("Move Up", systemImage: "arrow.up") { withMotion { draft.move(row.id, by: -1) } }
                .disabled(!draft.canMove(row.id, by: -1))
            Button("Move Down", systemImage: "arrow.down") { withMotion { draft.move(row.id, by: 1) } }
                .disabled(!draft.canMove(row.id, by: 1))
        }
        if draft.asksForMessage(row) {
            Button("Edit Message…", systemImage: "text.bubble") { editMessage(row) }
        }
    }
}

private struct PlanRow: View {
    var draft: InteractiveRebaseDraft
    var row: InteractiveRebaseDraft.Row
    var editMessage: () -> Void

    var body: some View {
        let commit = row.candidate.commit
        HStack(spacing: 10) {
            Picker("Action", selection: Binding { row.action } set: { draft.setAction($0, for: row.id) }) {
                ForEach(RebaseStep.Action.allCases, id: \.self) { action in
                    Text(action.title).tag(action)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(row.action.explanation)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .lineLimit(1)
                    .strikethrough(row.action == .drop)
                    .foregroundStyle(row.action == .drop ? .secondary : .primary)
                Text("\(commit.id.abbreviated()) · \(commit.author.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, row.action.meldsIntoPrevious ? 16 : 0)

            Spacer(minLength: 0)

            if draft.asksForMessage(row) {
                Button("Message…", action: editMessage)
                    .buttonStyle(.borderless)
                    .help("Edit the message the commit gets")
            }
        }
        .padding(.vertical, 2)
    }

    /// The subject the commit will have where that differs from its own.
    private var summary: String {
        guard draft.asksForMessage(row) else { return row.candidate.commit.summary }
        return draft.message(for: row.id).split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? row.candidate.commit.summary
    }
}

/// Edits a commit message in a sheet of its own.
struct MessageEditorSheet: View {
    var title: String
    @State var text: String
    var save: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetStack(title) {
            Form {
                SheetTitleSection()
                Section {
                    TextEditor(text: $text)
                        .font(.body)
                        .frame(minHeight: 160)
                }
            }
            .groupedFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .sheetMinimumSize(width: 460, height: 300)
    }
}
