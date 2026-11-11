import GitKit
import SwiftUI

/// Undo and Redo in the Edit menu, named for the operation they reverse.
///
/// On macOS they take the place of the system's items, whose ⌘Z would
/// otherwise never reach them: while a text field has focus they act on its
/// text, as the system's would, and on the repository otherwise.
struct UndoCommands: Commands {
    var model: RepositoryModel?

    var body: some Commands {
        if Platform.replacesUndoMenu {
            CommandGroup(replacing: .undoRedo) {
                UndoMenuItems(model: model, hasShortcuts: true)
            }
        } else {
            CommandGroup(after: .undoRedo) {
                UndoMenuItems(model: model, hasShortcuts: false)
            }
        }
    }
}

private struct UndoMenuItems: View {
    var model: RepositoryModel?
    var hasShortcuts: Bool

    var body: some View {
        let text = TextEditingUndo.shared
        if hasShortcuts, text.isEditing {
            Button(text.undoTitle) { text.perform(redo: false) }
                .keyboardShortcut("z")
                .disabled(!text.canUndo)
            Button(text.redoTitle) { text.perform(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!text.canRedo)
        } else {
            Button(model?.undoStack.undoMenuTitle ?? "Undo") {
                Task { await model?.undo() }
            }
            .keyboardShortcut(hasShortcuts ? KeyboardShortcut("z") : nil)
            .disabled(model?.canUndo != true)
            Button(model?.undoStack.redoMenuTitle ?? "Redo") {
                Task { await model?.redo() }
            }
            .keyboardShortcut(hasShortcuts ? KeyboardShortcut("z", modifiers: [.command, .shift]) : nil)
            .disabled(model?.canRedo != true)
        }
    }
}

extension View {
    /// Shows what undo needs from the user: a confirmation before rewriting
    /// pushed history, and why an undo could not go ahead. Where the menu bar
    /// is not at hand, adds Undo and Redo buttons too.
    func undoControls(for model: RepositoryModel) -> some View {
        modifier(UndoControls(model: model, undoStack: model.undoStack))
    }
}

private struct UndoControls: ViewModifier {
    var model: RepositoryModel
    @Bindable var undoStack: UndoStack

    func body(content: Content) -> some View {
        content
            .toolbar {
                if Platform.showsUndoButtons {
                    ToolbarItemGroup(placement: Platform.undoButtonPlacement) {
                        Button(undoStack.undoMenuTitle, systemImage: "arrow.uturn.backward") {
                            Task { await model.undo() }
                        }
                        .disabled(!model.canUndo)
                        Button(undoStack.redoMenuTitle, systemImage: "arrow.uturn.forward") {
                            Task { await model.redo() }
                        }
                        .disabled(!model.canRedo)
                    }
                }
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding { undoStack.pendingConfirmation != nil } set: {
                    if !$0 { undoStack.pendingConfirmation = nil }
                },
                titleVisibility: .visible,
                presenting: undoStack.pendingConfirmation
            ) { pending in
                Button(pending.direction == .undo ? "Undo Anyway" : "Redo Anyway", role: .destructive) {
                    Task { await model.confirm(pending) }
                }
            } message: { pending in
                Text(pending.message)
            }
            .alert(
                refusalTitle,
                isPresented: Binding { undoStack.refusal != nil } set: { if !$0 { undoStack.refusal = nil } },
                presenting: undoStack.refusal
            ) { refusal in
                Button("OK", role: .cancel) {}
                Button("Forget It") { undoStack.forget(refusal.record) }
            } message: { refusal in
                Text("\(refusal.message)\n\nIt stays in the undo history in case things change back; "
                     + "Forget It removes it and everything \(refusal.direction == .undo ? "before" : "after") it.")
            }
    }

    private var confirmationTitle: String {
        guard let pending = undoStack.pendingConfirmation else { return "" }
        return "\(pending.direction == .undo ? "Undo" : "Redo") “\(pending.record.title)”?"
    }

    private var refusalTitle: String {
        guard let refusal = undoStack.refusal else { return "" }
        return "Can’t \(refusal.direction == .undo ? "Undo" : "Redo") “\(refusal.record.title)”"
    }
}
