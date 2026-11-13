import GitKit
import SwiftUI

/// Creates an empty repository, optionally with a README and a .gitignore,
/// then adds it to the library and opens it.
struct NewRepositorySheet: View {
    var open: (RepositoryBookmark) -> Void

    @Environment(RepositoryLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// The folder the repository goes into, on macOS.
    @State private var parent: URL?
    @State private var isChoosingFolder = false
    @State private var branch = NewRepositoryPreferences.defaultBranch
    @State private var addsReadme = true
    @State private var ignoreTemplate = IgnoreTemplate.none
    @State private var isCreating = false
    @State private var error: Notice?

    var body: some View {
        SheetStack("New Repository") {
            Form {
                SheetTitleSection()
                Section {
                    TextField("Name", text: $name, prompt: Text("project"))
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                    if Platform.clonesIntoChosenFolder {
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
                    if !trimmedName.isEmpty, trimmedName.contains("/") {
                        Text("A name can’t contain a slash.").foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("Initial Branch", text: $branch, prompt: Text(NewRepositoryPreferences.standardBranch))
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                    Toggle("Add a README", isOn: $addsReadme)
                    Picker("Ignore Files", selection: $ignoreTemplate) {
                        ForEach(IgnoreTemplate.allCases) { template in
                            Text(template.title).tag(template)
                        }
                    }
                } footer: {
                    if !trimmedBranch.isEmpty, !Repository.isValidBranchName(trimmedBranch) {
                        Text("“\(trimmedBranch)” is not a valid branch name.").foregroundStyle(.red)
                    } else {
                        Text("A README or .gitignore is committed as the first commit when an author is set in Settings.")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(destination == nil || !Repository.isValidBranchName(resolvedBranch) || isCreating)
                }
            }
        }
        .frame(minWidth: 440)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): parent = url
            case .failure(let failure): error = Notice(failure)
            }
        }
        .notice(for: $error)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBranch: String {
        branch.trimmingCharacters(in: .whitespaces)
    }

    private var resolvedBranch: String {
        trimmedBranch.isEmpty ? NewRepositoryPreferences.standardBranch : trimmedBranch
    }

    private var destination: URL? {
        guard !trimmedName.isEmpty, !trimmedName.contains("/"), !trimmedName.hasPrefix(".") else { return nil }
        let base = Platform.clonesIntoChosenFolder ? parent : library.newRepositoryFolder
        return base?.appending(path: trimmedName, directoryHint: .isDirectory)
    }

    private var files: [String: String] {
        var files: [String: String] = [:]
        if addsReadme {
            files["README.md"] = "# \(trimmedName)\n"
        }
        if let ignore = ignoreTemplate.contents {
            files[".gitignore"] = ignore
        }
        return files
    }

    private func create() {
        guard let destination else { return }
        let options = NewRepositoryOptions(initialBranch: resolvedBranch, files: files)
        let parent = parent
        let name = trimmedName
        isCreating = true
        Task {
            let isScoped = parent?.startAccessingSecurityScopedResource() ?? false
            defer {
                if isScoped { parent?.stopAccessingSecurityScopedResource() }
            }
            let entry = ActivityLog.shared.begin("Create Repository", repository: name)
            do {
                if FileManager.default.fileExists(atPath: destination.path),
                   try !FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty {
                    throw NewRepositoryError.folderNotEmpty(name)
                }
                _ = try await Repository.create(at: destination, options: options)
                let bookmark = try library.add(destination)
                ActivityLog.shared.finish(entry, error: nil)
                dismiss()
                open(bookmark)
            } catch {
                ActivityLog.shared.finish(entry, error: error)
                isCreating = false
                self.error = Notice(error)
            }
        }
    }
}

private enum NewRepositoryError: LocalizedError {
    case folderNotEmpty(String)

    var errorDescription: String? {
        switch self {
        case .folderNotEmpty(let name):
            "There is already a folder named “\(name)” with files in it. Choose another name or location, or add that folder as a repository."
        }
    }
}

/// Starting .gitignore files for a few common kinds of project.
enum IgnoreTemplate: String, CaseIterable, Identifiable {
    case none
    case macOS
    case swift
    case node
    case python

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .macOS: "macOS"
        case .swift: "Swift and Xcode"
        case .node: "Node"
        case .python: "Python"
        }
    }

    var contents: String? {
        let system = ".DS_Store\n"
        return switch self {
        case .none: nil
        case .macOS: system
        case .swift: system + "\n.build/\nDerivedData/\n*.xcuserstate\nxcuserdata/\n.swiftpm/\n"
        case .node: system + "\nnode_modules/\ndist/\n.env\nnpm-debug.log*\n"
        case .python: system + "\n__pycache__/\n*.py[cod]\n.venv/\nvenv/\n.env\ndist/\nbuild/\n*.egg-info/\n"
        }
    }
}
