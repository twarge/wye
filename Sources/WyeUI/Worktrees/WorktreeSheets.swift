import GitKit
import SwiftUI

/// Asks what a new worktree checks out and where it goes.
struct AddWorktreeSheet: View {
    var model: RepositoryModel
    var initialTarget: WorktreeTarget?

    @Environment(RepositoryLibrary.self) private var library

    private enum Kind: String, CaseIterable, Identifiable {
        case branch, newBranch, detached
        var id: Self { self }
        var title: String {
            switch self {
            case .branch: "Branch"
            case .newBranch: "New Branch"
            case .detached: "Detached"
            }
        }
    }

    @State private var kind = Kind.newBranch
    @State private var branch = ""
    @State private var newBranch = ""
    @State private var folderName = ""
    @State private var hasEditedFolder = false
    @State private var parent: URL?
    @State private var isChoosingFolder = false
    @State private var opensAfterwards = true
    @State private var error: Notice?

    var body: some View {
        BranchingSheetForm(title: "Add Worktree", confirmTitle: "Add", canConfirm: target != nil && location != nil, confirm: add) {
            Section {
                Picker("Check Out", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                switch kind {
                case .branch:
                    Picker("Branch", selection: $branch) {
                        ForEach(availableBranches) { branch in
                            Text(branch.name).tag(branch.id)
                        }
                    }
                case .newBranch:
                    TextField("Branch Name", text: $newBranch)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                    LabeledContent("Starts At", value: startingPoint?.abbreviated() ?? "Nothing to start from")
                        .font(.code)
                case .detached:
                    LabeledContent("Commit", value: startingPoint?.abbreviated() ?? "None")
                        .font(.code)
                }
            } footer: {
                Text("A branch can be checked out in one worktree at a time. Branches checked out elsewhere are not listed.")
            }

            Section {
                TextField("Folder Name", text: Binding { folderName } set: {
                    folderName = $0
                    hasEditedFolder = true
                })
                .autocorrectionDisabled()
                .noAutocapitalization()
                if Platform.placesWorktreesInChosenFolder {
                    LabeledContent("Location") {
                        HStack {
                            Text(parent?.lastPathComponent ?? "None")
                                .foregroundStyle(parent == nil ? .secondary : .primary)
                            Button("Choose…") { isChoosingFolder = true }
                        }
                    }
                } else {
                    LabeledContent("Location", value: library.newRepositoryFolderTitle)
                }
                Toggle("Open After Adding", isOn: $opensAfterwards)
            } footer: {
                Text("Wye makes a new folder of that name in the location, and checks the worktree out there.")
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): parent = url
            case .failure(let failure): error = Notice(failure)
            }
        }
        .fileDialogDefaultDirectory(model.repository.url.deletingLastPathComponent())
        .notice(for: $error)
        .onAppear(perform: start)
        .onChange(of: suggestedFolder) {
            if !hasEditedFolder { folderName = suggestedFolder }
        }
    }

    /// Local branches no worktree has checked out.
    private var availableBranches: [Branch] {
        (model.snapshot?.branches ?? []).filter { !$0.isHead && $0.worktreePath == nil }
    }

    private var startingPoint: OID? {
        switch initialTarget {
        case .newBranch(_, let commit), .detached(let commit): commit
        case .branch, nil: model.snapshot?.head.target
        }
    }

    private var target: WorktreeTarget? {
        switch kind {
        case .branch:
            branch.isEmpty ? nil : .branch(branch)
        case .newBranch:
            newBranch.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : startingPoint.map { .newBranch(newBranch.trimmingCharacters(in: .whitespaces), at: $0) }
        case .detached:
            startingPoint.map(WorktreeTarget.detached)
        }
    }

    private var location: URL? {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return Platform.placesWorktreesInChosenFolder ? parent : library.newRepositoryFolder
    }

    private var suggestedFolder: String {
        let base = model.repository.url.lastPathComponent
        let branchName = switch kind {
        case .branch: RepositoryModel.displayName(ofReference: branch)
        case .newBranch: newBranch
        case .detached: startingPoint?.abbreviated() ?? ""
        }
        let cleaned = branchName.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? base : "\(base)-\(cleaned)"
    }

    private func start() {
        switch initialTarget {
        case .branch(let name):
            kind = .branch
            branch = name
        case .detached:
            kind = .detached
        case .newBranch(let name, _):
            kind = .newBranch
            newBranch = name
        case nil:
            branch = availableBranches.first?.id ?? ""
        }
        folderName = suggestedFolder
    }

    private func add() {
        guard let target, let location else { return }
        let name = folderName.trimmingCharacters(in: .whitespaces)
        let library = library, open = opensAfterwards
        Task { await model.addWorktree(named: name, in: location, target: target, library: library, open: open) }
    }
}

/// Asks why a worktree is being locked.
struct LockWorktreeSheet: View {
    var model: RepositoryModel
    var name: String

    @State private var reason = ""

    var body: some View {
        BranchingSheetForm(title: "Lock Worktree", confirmTitle: "Lock", confirm: lock) {
            Section {
                TextField("Reason", text: $reason, prompt: Text("Optional, such as “On an external disk”"))
            } footer: {
                Text("A locked worktree is not pruned while its folder is away, and cannot be moved or removed until unlocked.")
            }
        }
    }

    private func lock() {
        let reason = reason, name = name
        Task { await model.lockWorktree(name, reason: reason) }
    }
}

/// Asks where a worktree goes.
struct MoveWorktreeSheet: View {
    var model: RepositoryModel
    var name: String

    @Environment(RepositoryLibrary.self) private var library
    @State private var folderName = ""
    @State private var parent: URL?
    @State private var isChoosingFolder = false
    @State private var error: Notice?

    var body: some View {
        BranchingSheetForm(title: "Move Worktree", confirmTitle: "Move", canConfirm: destinationParent != nil, confirm: move) {
            Section {
                TextField("Folder Name", text: $folderName)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                if Platform.placesWorktreesInChosenFolder {
                    LabeledContent("Location") {
                        HStack {
                            Text(parent?.lastPathComponent ?? "None")
                                .foregroundStyle(parent == nil ? .secondary : .primary)
                            Button("Choose…") { isChoosingFolder = true }
                        }
                    }
                } else {
                    LabeledContent("Location", value: library.newRepositoryFolderTitle)
                }
            } footer: {
                Text("The worktree’s folder moves there, and the repository is told where it went.")
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): parent = url
            case .failure(let failure): error = Notice(failure)
            }
        }
        .notice(for: $error)
        .onAppear {
            folderName = model.worktree(named: name)?.displayName ?? name
        }
    }

    private var destinationParent: URL? {
        let trimmed = folderName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        return Platform.placesWorktreesInChosenFolder ? parent : library.newRepositoryFolder
    }

    private func move() {
        guard let destinationParent else { return }
        let folder = folderName.trimmingCharacters(in: .whitespaces), name = name, library = library
        Task { await model.moveWorktree(name, into: destinationParent, folderName: folder, library: library) }
    }
}

/// Confirms removing a worktree, saying what is lost.
struct RemoveWorktreeSheet: View {
    var model: RepositoryModel
    var name: String

    @Environment(RepositoryLibrary.self) private var library
    /// How many files differ in it; `nil` until counted, or when it cannot be.
    @State private var changes: Int?
    @State private var isCounting = true

    var body: some View {
        let worktree = model.worktree(named: name)
        BranchingSheetForm(
            title: "Remove Worktree", confirmTitle: changes ?? 0 > 0 ? "Remove Anyway" : "Remove",
            isDestructive: true, canConfirm: !isCounting, confirm: remove
        ) {
            Section {
                LabeledContent("Worktree", value: worktree?.displayName ?? name)
                if let worktree {
                    LabeledContent("Path", value: worktree.path)
                    LabeledContent("Checked Out", value: worktree.headSummary)
                }
            } footer: {
                Text(explanation)
            }
        }
        .task {
            defer { isCounting = false }
            guard let worktree, !worktree.isMissing else { return }
            let url = URL(filePath: worktree.path, directoryHint: .isDirectory)
            let access = library.bookmark(at: url).flatMap { try? library.access(to: $0) }
            defer { withExtendedLifetime(access) {} }
            if let repository = try? Repository(at: url) {
                changes = (try? await repository.status())?.count
            }
        }
    }

    private var explanation: String {
        let folder = "The worktree’s folder is deleted. Its branch and commits stay in the repository."
        switch changes {
        case let count? where count > 0:
            return "\(folder) It has \(count) uncommitted \(count == 1 ? "change" : "changes") or untracked "
                + "\(count == 1 ? "file" : "files"), which \(count == 1 ? "is" : "are") lost and cannot be recovered."
        case 0:
            return "\(folder) It has no uncommitted changes."
        default:
            return "\(folder) Any uncommitted changes or untracked files in it are lost and cannot be recovered."
        }
    }

    private func remove() {
        let name = name, library = library
        Task { await model.removeWorktree(name, force: true, library: library) }
    }
}
