import GitKit
import QuickLook
import SwiftUI

/// The actions on a changed file beyond staging and discarding: open it,
/// copy its path, rename it, ignore it, stop tracking it.
struct WorkingCopyFileMenu: View {
    var model: RepositoryModel
    var entry: StatusEntry

    var body: some View {
        let path = entry.path
        let isOnDisk = entry.unstaged != .deleted
        // In the index: neither untracked nor staged for deletion.
        let isTracked = entry.unstaged != .untracked && entry.staged != .deleted
        if isOnDisk {
            OpenFileButtons(model: model, path: path)
        }
        CopyPathMenu(model: model, path: path)
        Section {
            if isOnDisk, !entry.isConflicted {
                Button("Rename or Move…", systemImage: "pencil") {
                    model.fileRequests.pending = .rename(path: path)
                }
            }
            if entry.unstaged == .untracked {
                Button("\(Platform.trashTitle)…", systemImage: "trash", role: .destructive) {
                    model.fileRequests.pending = .trash(path: path)
                }
            }
        }
        Section {
            IgnoreMenu(model: model, path: path, isFolder: false)
            if isTracked, !entry.isConflicted {
                Button("Stop Tracking…", systemImage: "eye.slash") {
                    model.fileRequests.pending = .stopTracking(paths: [path], afterIgnoring: false)
                }
                Button("Assume Unchanged", systemImage: "lock") {
                    Task { await model.setAssumeUnchanged(true, for: [path]) }
                }
                .help("Stop looking for changes to this file until this is undone")
            }
        }
    }
}

/// The actions on a folder of the tree of changed files.
struct WorkingCopyFolderMenu: View {
    var model: RepositoryModel
    var node: FileTreeNode

    var body: some View {
        let path = node.path
        if Platform.canRevealFiles, model.fileExists(path) {
            Button(Platform.revealInFileBrowserTitle, systemImage: "folder") {
                Platform.revealInFileBrowser(model.fileURL(for: path))
            }
        }
        CopyPathMenu(model: model, path: path)
        Section {
            IgnoreMenu(model: model, path: path, isFolder: true)
            let tracked = node.entries.filter { $0.unstaged != .untracked && $0.staged != .deleted && !$0.isConflicted }
            if !tracked.isEmpty {
                Button("Stop Tracking Folder…", systemImage: "eye.slash") {
                    model.fileRequests.pending = .stopTracking(paths: [path + "/"], afterIgnoring: false)
                }
            }
        }
    }
}

/// The actions on an ignored or assumed-unchanged file, which git does not
/// list as changed.
struct WorkingCopyHiddenFileMenu: View {
    var model: RepositoryModel
    /// A folder's ends in `/`.
    var path: String

    var body: some View {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if model.fileExists(trimmed) {
            if path.hasSuffix("/") {
                if Platform.canRevealFiles {
                    Button(Platform.revealInFileBrowserTitle, systemImage: "folder") {
                        Platform.revealInFileBrowser(model.fileURL(for: trimmed))
                    }
                }
            } else {
                OpenFileButtons(model: model, path: trimmed)
            }
        }
        CopyPathMenu(model: model, path: trimmed)
    }
}

/// Open, Quick Look and Reveal for a file that is on disk.
private struct OpenFileButtons: View {
    var model: RepositoryModel
    var path: String

    var body: some View {
        let url = model.fileURL(for: path)
        Section {
            if Platform.canOpenFilesInOtherApps {
                Button("Open", systemImage: "arrow.up.forward.app") {
                    Platform.openWithDefaultApp(url)
                }
                .help("Open the file in the app the system uses for it")
            }
            Button("Quick Look", systemImage: "eye") {
                model.fileRequests.quickLook = url
            }
            if Platform.canRevealFiles {
                Button(Platform.revealInFileBrowserTitle, systemImage: "folder") {
                    Platform.revealInFileBrowser(url)
                }
            }
        }
    }
}

/// Copies a path as git names it, or as the file system does.
private struct CopyPathMenu: View {
    var model: RepositoryModel
    var path: String

    var body: some View {
        Menu("Copy Path", systemImage: "doc.on.doc") {
            Button("Relative Path") { Platform.copyToClipboard(path) }
            Button("Full Path") { Platform.copyToClipboard(model.fileURL(for: path).path) }
        }
    }
}

/// Ignore rules for a file or folder, in `.gitignore` or kept to this clone.
private struct IgnoreMenu: View {
    var model: RepositoryModel
    var path: String
    var isFolder: Bool

    @Environment(\.requestCustomIgnore) private var requestCustomIgnore

    var body: some View {
        Menu("Add to .gitignore", systemImage: "eye.slash.circle") {
            choices(in: .shared)
            customPattern(in: .shared)
            Divider()
            Menu("Ignore Privately") {
                choices(in: .local)
                customPattern(in: .local)
            }
            .help("Rules kept in .git/info/exclude, which is never committed")
        }
    }

    /// A rule of one's own, starting from this file's or folder's.
    private func customPattern(in file: IgnoreFile) -> some View {
        Button("Custom Pattern…") {
            requestCustomIgnore(CustomIgnoreRequest(
                pattern: isFolder ? IgnorePattern.folder(path) : IgnorePattern.file(path), file: file
            ))
        }
    }

    @ViewBuilder
    private func choices(in file: IgnoreFile) -> some View {
        let parts = path.splitPath
        if isFolder {
            button("Folder “\(parts.name)”", IgnorePattern.folder(path), file)
        } else {
            button("“\(parts.name)”", IgnorePattern.file(path), file)
            if !parts.folder.isEmpty {
                button("Folder “\(parts.folder.splitPath.name)”", IgnorePattern.folder(parts.folder), file)
            }
            if let pattern = IgnorePattern.fileExtension(of: path), let name = IgnorePattern.extensionName(of: path) {
                button("All “\(name)” Files", pattern, file)
            }
        }
    }

    private func button(_ title: String, _ pattern: String, _ file: IgnoreFile) -> some View {
        Button(title) {
            Task { await model.ignore(pattern, in: file) }
        }
        .help("Adds “\(pattern)” to \(file == .shared ? ".gitignore" : ".git/info/exclude")")
    }
}

extension FileActions {
    /// An action on a commit's file that runs at once.
    struct Command: Identifiable {
        var title: String
        var systemImage: String
        var action: @MainActor () -> Void

        var id: String { title }
    }

    /// These actions with the working copy's on top: restoring the file,
    /// copying its path, finding it on disk.
    func adding(workingCopyCommandsFor file: FileDiff, in commitID: OID, model: RepositoryModel) -> FileActions {
        var actions = self
        guard !model.repository.isBare else { return actions }
        let path = file.path
        if file.change != .deleted {
            actions.commands.append(Command(title: "Restore This Version to Working Copy", systemImage: "arrow.uturn.backward") {
                Task { await model.requestRestore(path, from: commitID) }
            })
        }
        actions.commands.append(Command(title: "Copy Path", systemImage: "doc.on.doc") {
            Platform.copyToClipboard(path)
        })
        actions.commands.append(Command(title: "Copy Full Path", systemImage: "doc.on.doc") {
            Platform.copyToClipboard(model.fileURL(for: path).path)
        })
        if Platform.canRevealFiles {
            actions.commands.append(Command(title: Platform.revealInFileBrowserTitle, systemImage: "folder") {
                let url = model.fileURL(for: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    Platform.revealInFileBrowser(url)
                } else {
                    model.report(FileOperationError.sourceMissing(path))
                }
            })
        }
        return actions
    }
}

/// The commands of a file's actions, after a divider, for its context menu.
struct FileCommandButtons: View {
    var commands: [FileActions.Command]

    var body: some View {
        if !commands.isEmpty {
            Divider()
            ForEach(commands) { command in
                Button(command.title, systemImage: command.systemImage) { command.action() }
            }
        }
    }
}

extension View {
    /// The confirmations, the rename prompt and Quick Look for file actions
    /// asked for anywhere in a repository window.
    func fileRequestDialogs(_ model: RepositoryModel) -> some View {
        modifier(FileRequestDialogs(model: model, requests: model.fileRequests))
    }
}

private struct FileRequestDialogs: ViewModifier {
    var model: RepositoryModel
    @Bindable var requests: FileRequests

    @State private var newPath = ""

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                confirmationTitle,
                isPresented: binding(isShown: { $0.needsConfirmation }),
                titleVisibility: .visible,
                presenting: requests.pending
            ) { request in
                switch request {
                case .trash(let path):
                    Button(Platform.trashTitle, role: .destructive) {
                        Task { await model.trashUntrackedFile(path) }
                    }
                case .stopTracking(let paths, _):
                    Button("Stop Tracking", role: .destructive) {
                        Task { await model.stopTracking(paths) }
                    }
                case .restore(let path, let commit):
                    Button("Restore", role: .destructive) {
                        Task { await model.restore(path, from: commit) }
                    }
                case .rename:
                    EmptyView()
                }
            } message: { request in
                Text(message(for: request))
            }
            .alert(
                "Rename or Move",
                isPresented: binding(isShown: { if case .rename = $0 { true } else { false } }),
                presenting: requests.pending
            ) { request in
                if case .rename(let path) = request {
                    TextField("New Path", text: $newPath)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                    Button("Cancel", role: .cancel) {}
                    Button("Move") {
                        let destination = newPath
                        Task { await model.moveFile(path, to: destination) }
                    }
                    .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty || newPath == path)
                }
            } message: { request in
                if case .rename(let path) = request {
                    Text("A new path for “\(path)”, from the top of the repository. A tracked file’s move is staged, as git mv stages it.")
                }
            }
            .onChange(of: requests.pending) {
                if case .rename(let path) = requests.pending {
                    newPath = path
                }
            }
            .quickLookPreview($requests.quickLook)
    }

    private func binding(isShown: @escaping (FileRequest) -> Bool) -> Binding<Bool> {
        Binding {
            requests.pending.map(isShown) ?? false
        } set: { isPresented in
            if !isPresented, let pending = requests.pending, isShown(pending) {
                requests.pending = nil
            }
        }
    }

    private var confirmationTitle: String {
        switch requests.pending {
        case .trash(let path): "\(Platform.trashTitle) “\(path.splitPath.name)”?"
        case .stopTracking(let paths, true):
            paths.count == 1
                ? "Stop Tracking “\(paths[0].splitPath.name)” Too?"
                : "Stop Tracking the \(paths.count.formatted()) Tracked Files the Rule Matches?"
        case .stopTracking(let paths, false):
            paths.count == 1 ? "Stop Tracking “\(paths[0].splitPath.name)”?" : "Stop Tracking \(paths.count.formatted()) Files?"
        case .restore(let path, _): "Replace the Working Copy’s “\(path.splitPath.name)”?"
        case .rename, nil: ""
        }
    }

    private func message(for request: FileRequest) -> String {
        switch request {
        case .trash(let path):
            return "“\(path)” is not tracked, so git has no copy of it. \(Platform.trashNote)"
        case .stopTracking(let paths, let afterIgnoring):
            let subject = paths.count == 1 ? "“\(paths[0])”" : paths.prefix(5).map { "“\($0)”" }.joined(separator: ", ")
                + (paths.count > 5 ? " and \((paths.count - 5).formatted()) more" : "")
            let why = afterIgnoring ? "git keeps showing changes to tracked files, even ignored ones. " : ""
            return "\(why)\(subject) stays on disk as it is, but leaves the index: the next commit removes it from the repository, and from other working copies when they pull it. Changes staged for it are unstaged."
        case .restore(let path, let commit):
            return "“\(path)” in the working tree becomes its version at \(commit.abbreviated()). Its changes that are not staged are lost and cannot be recovered; staged changes stay in the index."
        case .rename:
            return ""
        }
    }
}

private extension FileRequest {
    var needsConfirmation: Bool {
        if case .rename = self { false } else { true }
    }
}
