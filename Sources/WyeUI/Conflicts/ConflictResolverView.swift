import GitKit
import SwiftUI

/// Resolves one conflicted file: line by line for text, or by choosing a
/// side whole for anything else. Nothing changes until it is saved.
struct ConflictResolverView: View {
    @Bindable var model: RepositoryModel
    var path: String

    @Environment(\.dismiss) private var dismiss
    @State private var file: ConflictFile?
    @State private var session: TextResolution?
    @State private var failure: String?
    @State private var isSaving = false
    @State private var isConfirmingCancel = false

    var body: some View {
        SheetStack(path.splitPath.name, subtitle: path.splitPath.folder, placement: .above(inset: 16)) {
            content
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) {
                            if hasChoices { isConfirmingCancel = true } else { dismiss() }
                        }
                    }
                    if session != nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { Task { await save() } }
                                .disabled(!(session?.isComplete ?? false) || isSaving)
                                .help("Write the result to the file and mark it resolved")
                        }
                    }
                }
        }
        .sheetMinimumSize(width: 820, height: 640)
        .interactiveDismissDisabled(hasChoices)
        .confirmationDialog("Discard Your Choices?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button("Discard Choices", role: .destructive) { dismiss() }
        } message: {
            Text("The file stays as it is, still in conflict.")
        }
        .sheetNotices(model)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            ContentUnavailableView(
                "Can’t Open the Conflict", systemImage: "exclamationmark.triangle", description: Text(failure)
            )
        } else if let file {
            switch file.content {
            case .text:
                if let binding = Binding($session) {
                    TextConflictEditor(session: binding, labels: file.labels, hasBase: file.hasBase)
                }
            case .whole, .deleted, .deletedOnBothSides:
                WholeFileChoice(file: file) { side in
                    Task {
                        if await model.resolveConflictWhole(at: path, using: side) { dismiss() }
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hasChoices: Bool {
        (session?.remaining ?? 0) < (session?.count ?? 0)
    }

    private func load() async {
        do {
            let file = try await model.repository.conflictFile(at: path)
            if case .text(let text) = file.content {
                session = TextResolution(text: text)
            }
            self.file = file
        } catch {
            failure = error.localizedDescription
        }
    }

    private func save() async {
        guard let file, let text = session?.result else { return }
        isSaving = true
        defer { isSaving = false }
        if await model.saveConflictResolution(of: file, text: text) {
            dismiss()
        }
    }
}

// MARK: Text

/// The current conflict above the merged result; on a narrow screen, one or
/// the other.
private struct TextConflictEditor: View {
    @Binding var session: TextResolution
    var labels: ConflictLabels
    var hasBase: Bool

    private enum Pane: Hashable {
        case conflict
        case result
    }

    @State private var pane = Pane.conflict

    var body: some View {
        VStack(spacing: 0) {
            ConflictNavigator(session: $session)
            GeometryReader { geometry in
                if geometry.size.width >= 640 {
                    VStack(spacing: 0) {
                        conflictPanel(sideBySide: true)
                            .frame(height: geometry.size.height * 0.55)
                        Divider()
                        ResultPane(session: $session, labels: labels)
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("Show", selection: $pane) {
                            Text("Conflict").tag(Pane.conflict)
                            Text("Result").tag(Pane.result)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        switch pane {
                        case .conflict: conflictPanel(sideBySide: false)
                        case .result: ResultPane(session: $session, labels: labels)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func conflictPanel(sideBySide: Bool) -> some View {
        if session.count == 0 {
            ContentUnavailableView(
                "No Conflicting Lines",
                systemImage: "checkmark.circle",
                description: Text("The two sides merged by themselves. Save to take the result.")
            )
        } else {
            ConflictPanel(session: $session, labels: labels, hasBase: hasBase, sideBySide: sideBySide)
        }
    }
}

/// Which conflict is showing, how many are left, and the way between them.
private struct ConflictNavigator: View {
    @Binding var session: TextResolution

    var body: some View {
        HStack(spacing: 12) {
            ControlGroup {
                Button("Previous Conflict", systemImage: "chevron.up") { session.previous() }
                    .disabled(!session.canGoBack)
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Conflict", systemImage: "chevron.down") { session.next() }
                    .disabled(!session.canGoForward)
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            if session.count > 0 {
                Text("Conflict \(session.current + 1) of \(session.count)")
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Label(remainingText, systemImage: session.isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(session.isComplete ? .green : .orange)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var remainingText: String {
        switch session.remaining {
        case 0: "All resolved"
        case 1: "1 conflict left"
        default: "\(session.remaining) conflicts left"
        }
    }
}

/// One conflict: both sides, the base on request, and the ways to settle it.
private struct ConflictPanel: View {
    @Binding var session: TextResolution
    var labels: ConflictLabels
    var hasBase: Bool
    var sideBySide: Bool

    @State private var draft: String?
    @State private var showsBase = false

    var body: some View {
        ScrollView {
            if let conflict = session.currentConflict {
                VStack(alignment: .leading, spacing: 14) {
                    ResolutionButtons(session: $session, labels: labels) {
                        draft = session.draftForCurrent
                    }
                    if let draft {
                        editor(draft)
                    }
                    sides(conflict)
                    base(conflict)
                }
                .padding(16)
            }
        }
        // A draft belongs to the conflict it was started on.
        .onChange(of: session.current) { draft = nil }
    }

    @ViewBuilder
    private func sides(_ conflict: TextConflict) -> some View {
        let resolution = session.resolution(of: session.current)
        let takesOurs: [ConflictResolution] = [.ours, .oursThenTheirs, .theirsThenOurs]
        let takesTheirs: [ConflictResolution] = [.theirs, .oursThenTheirs, .theirsThenOurs]
        let ours = ConflictSideBox(
            heading: labels.ours.heading, explanation: labels.ours.explanation, lines: conflict.ours,
            tint: .blue, isChosen: resolution.map(takesOurs.contains) ?? false
        )
        let theirs = ConflictSideBox(
            heading: labels.theirs.heading, explanation: labels.theirs.explanation, lines: conflict.theirs,
            tint: .purple, isChosen: resolution.map(takesTheirs.contains) ?? false
        )
        if sideBySide {
            HStack(alignment: .top, spacing: 12) { ours; theirs }
        } else {
            VStack(alignment: .leading, spacing: 12) { ours; theirs }
        }
    }

    @ViewBuilder
    private func base(_ conflict: TextConflict) -> some View {
        if hasBase {
            DisclosureGroup("Base", isExpanded: $showsBase) {
                ConflictSideBox(
                    heading: "Base", explanation: labels.baseExplanation, lines: conflict.base,
                    tint: .gray, isChosen: session.resolution(of: session.current) == .base
                )
                .padding(.top, 6)
            }
        } else {
            Text("There is no base: both sides added this file, so every line of it is a change.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func editor(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit the Result")
                .font(.headline)
            TextEditor(text: Binding { draft ?? text } set: { draft = $0 })
                .font(.code)
                .autocorrectionDisabled()
                .noAutocapitalization()
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Cancel Editing") { draft = nil }
                Spacer()
                Button("Use This Text") {
                    session.resolveCurrent(.edited(draft ?? text))
                    draft = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The choices for the current conflict.
private struct ResolutionButtons: View {
    @Binding var session: TextResolution
    var labels: ConflictLabels
    var edit: () -> Void

    var body: some View {
        let ours = labels.ours.title, theirs = labels.theirs.title
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                choice("Take \(ours)", .ours)
                choice("Take \(theirs)", .theirs)
                choice("Both, \(ours) First", .oursThenTheirs)
                choice("Both, \(theirs) First", .theirsThenOurs)
                choice("Take Base", .base)
                Button("Edit…", action: edit)
                reopen
            }
            HStack(spacing: 8) {
                choice("Take \(ours)", .ours)
                choice("Take \(theirs)", .theirs)
                Menu("More") {
                    Button("Both, \(ours) First") { session.resolveCurrent(.oursThenTheirs) }
                    Button("Both, \(theirs) First") { session.resolveCurrent(.theirsThenOurs) }
                    Button("Take Base") { session.resolveCurrent(.base) }
                    Button("Edit…", action: edit)
                    if session.resolution(of: session.current) != nil {
                        Divider()
                        Button("Leave Unresolved") { session.clearCurrent() }
                    }
                }
                .fixedSize()
            }
        }
        .buttonStyle(.bordered)
    }

    private func choice(_ title: String, _ resolution: ConflictResolution) -> some View {
        let isChosen = session.resolution(of: session.current) == resolution
        return Button(title) { session.resolveCurrent(resolution) }
            .tint(isChosen ? Color.accentColor : nil)
            .fixedSize()
    }

    @ViewBuilder
    private var reopen: some View {
        if session.resolution(of: session.current) != nil {
            Button("Leave Unresolved", systemImage: "arrow.uturn.backward") { session.clearCurrent() }
                .labelStyle(.iconOnly)
                .help("Undo the choice for this conflict")
        }
    }
}

/// One side's lines, labelled with what that side is.
private struct ConflictSideBox: View {
    var heading: String
    var explanation: String
    var lines: [String]
    var tint: Color
    var isChosen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(heading)
                    .font(.headline)
                    .lineLimit(1)
                if isChosen {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tint)
                        .accessibilityLabel("Chosen")
                }
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if lines.isEmpty {
                    Text("No lines")
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        Text(TextResolution.display(lines))
                            .textSelection(.enabled)
                            .fixedSize()
                    }
                }
            }
            .font(.code)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isChosen ? tint : tint.opacity(0.25), lineWidth: isChosen ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The whole file as it will be saved, with open conflicts between markers.
private struct ResultPane: View {
    @Binding var session: TextResolution
    var labels: ConflictLabels

    var body: some View {
        let segments = session.segments(oursLabel: labels.ours.markerLabel, theirsLabel: labels.theirs.markerLabel)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Result")
                    .font(.headline)
                Text("as it will be saved")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(segments) { segment in
                            row(segment)
                                .id(segment.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: session.current, initial: true) {
                    guard let target = segments.first(where: { $0.conflict == session.current }) else { return }
                    withMotion { proxy.scrollTo(target.id, anchor: .center) }
                }
            }
        }
        .background(.background)
    }

    private func row(_ segment: TextResolution.Segment) -> some View {
        let isCurrent = segment.conflict == session.current
        return Group {
            if segment.text.isEmpty, segment.conflict != nil {
                Text("Nothing: these lines are removed")
                    .italic()
                    .foregroundStyle(.secondary)
            } else {
                Text(segment.text)
                    .textSelection(.enabled)
            }
        }
        .font(.code)
        .padding(.horizontal, 16)
        .padding(.vertical, segment.conflict == nil ? 0 : 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(of: segment))
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let conflict = segment.conflict { session.go(to: conflict) }
        }
        .accessibilityAddTraits(segment.conflict == nil ? [] : .isButton)
    }

    private func background(of segment: TextResolution.Segment) -> Color {
        switch segment.kind {
        case .merged: .clear
        case .resolved: .green.opacity(0.10)
        case .open: .orange.opacity(0.15)
        }
    }
}

// MARK: Whole files

/// A conflict that cannot be merged by line: keep one side, or the file
/// or its deletion.
private struct WholeFileChoice: View {
    var file: ConflictFile
    var choose: (ConflictSide) -> Void

    @State private var pending: ConflictSide?

    var body: some View {
        Form {
            Section {
                Text(explanation)
            }
            Section {
                ForEach(options, id: \.side) { option in
                    Button(option.title, role: option.isDeletion ? .destructive : nil) { pending = option.side }
                }
            } footer: {
                Text(footer)
            }
        }
        .groupedFormStyle()
        .confirmationDialog(
            pending.map(confirmationTitle) ?? "",
            isPresented: Binding { pending != nil } set: { if !$0 { pending = nil } },
            titleVisibility: .visible,
            presenting: pending
        ) { side in
            Button(options.first { $0.side == side }?.title ?? "Resolve", role: .destructive) { choose(side) }
        } message: { _ in
            Text("Whatever the other side did to the file, and any edits made to it while resolving, are lost.")
        }
    }

    private struct Option {
        var side: ConflictSide
        var title: String
        var isDeletion = false
    }

    private func label(_ side: ConflictSide) -> ConflictSideLabel {
        side == .ours ? file.labels.ours : file.labels.theirs
    }

    private var options: [Option] {
        switch file.content {
        case .deleted(let deleter):
            let keeper: ConflictSide = deleter == .ours ? .theirs : .ours
            return [
                Option(side: keeper, title: "Keep the File (\(label(keeper).title) Version)"),
                Option(side: deleter, title: "Delete the File", isDeletion: true),
            ]
        case .deletedOnBothSides:
            return [Option(side: .ours, title: "Delete the File", isDeletion: true)]
        case .whole, .text:
            return [
                Option(side: .ours, title: "Use \(file.labels.ours.title) Version"),
                Option(side: .theirs, title: "Use \(file.labels.theirs.title) Version"),
            ]
        }
    }

    private var explanation: String {
        switch file.content {
        case .deleted(let deleter):
            let keeper: ConflictSide = deleter == .ours ? .theirs : .ours
            return "\(label(deleter).heading) deleted “\(file.path)”, and \(label(keeper).heading) changed it."
        case .deletedOnBothSides:
            return "Both sides took “\(file.path)” away, as when each renamed it differently."
        case .whole, .text:
            return "“\(file.path)” is not text that can be merged line by line, so one side’s version is taken whole."
        }
    }

    private var footer: String {
        [file.labels.ours, file.labels.theirs].map { "\($0.title): \($0.explanation)" }.joined(separator: "\n")
    }

    private func confirmationTitle(_ side: ConflictSide) -> String {
        options.first { $0.side == side }.map { "\($0.title)?" } ?? ""
    }
}

// MARK: Presenting

/// A conflicted file to open in the resolver.
struct ConflictTarget: Identifiable, Hashable {
    var path: String
    var id: String { path }
}

extension View {
    /// Shows the resolver for the conflicted file in `target` while it is set.
    func conflictResolver(for target: Binding<ConflictTarget?>, model: RepositoryModel) -> some View {
        sheet(item: target) { target in
            ConflictResolverView(model: model, path: target.path)
        }
    }
}
