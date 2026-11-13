import CoreGraphics
import Foundation
import GitKit
import QuickLook
import QuickLookThumbnailing
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

// MARK: Files written for previews

/// Where files written for Quick Look wait: each preview's in a folder of
/// its own, which goes when the preview does. Emptied when the app starts.
enum PreviewFiles {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Wye Previews", directoryHint: .isDirectory)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The name a side of a file is written under for a preview: the file's
    /// own name and extension, which is how Quick Look knows what it is.
    static func fileName(for path: String, repositoryName: String = "") -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        return DragFiles.safeName(name.isEmpty ? repositoryName : name)
    }

    /// The name a file or folder gets when it is written out of `source`:
    /// its own name from the working tree; from a commit, the commit's hash
    /// added, so that it does not pass for the current one; from the index,
    /// "staged" added.
    static func exportName(for path: String, source: ContentSource, repositoryName: String = "") -> String {
        let name = fileName(for: path, repositoryName: repositoryName)
        switch source {
        case .workingTree: return name
        case .commit(let id): return FileDrag.fileName(for: name, commit: id)
        case .index: return FileDrag.fileName(for: name, suffix: "staged")
        }
    }
}

/// A folder of files written for a preview, removed when nothing holds it.
final class PreviewFolder: Sendable {
    let url: URL

    init() throws {
        url = PreviewFiles.folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Where a copy goes, in a subfolder such as `Before`, so that two sides
    /// can both have the file's own name.
    func location(of name: String, in subfolder: String) -> URL {
        url.appending(path: subfolder, directoryHint: .isDirectory).appending(path: name)
    }
}

// MARK: Pictures from Quick Look

/// The pictures Quick Look draws of a file's content, by the same
/// extensions Finder uses, including those apps add for their own files.
enum QuickLookThumbnail {
    /// A picture of what a file or package holds, at most `size` points;
    /// `nil` when Quick Look has nothing better than the icon for its type,
    /// or cannot read it. Cancelling the task cancels the request.
    nonisolated static func make(for url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        let request = Unchecked(QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale,
            // Asking for only a thumbnail is what tells one from an icon:
            // without a real one the request fails rather than fall back.
            representationTypes: .thumbnail
        ))
        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Unchecked<CGImage?>, Never>) in
                // A cancelled request still calls back, with an error.
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request.value) { representation, _ in
                    continuation.resume(returning: Unchecked(representation?.type == .thumbnail ? representation?.cgImage : nil))
                }
            }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request.value)
        }
        return image.value
    }
}

/// A value handed between tasks that is not marked sendable but is only
/// read once it arrives.
struct Unchecked<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// The kinds of file Quick Look had no picture for, so that their previews
/// are not tried again while the app runs.
enum QuickLookTypes {
    private static let withoutPreview = Mutex<Set<String>>([])

    /// `folder:horizontal` or `file:pdf`.
    static func key(for name: String, isFolder: Bool) -> String {
        "\(isFolder ? "folder" : "file"):\((name as NSString).pathExtension.lowercased())"
    }

    static func hasNoPreview(_ key: String) -> Bool {
        withoutPreview.withLock { $0.contains(key) }
    }

    static func setHasNoPreview(_ key: String) {
        _ = withoutPreview.withLock { $0.insert(key) }
    }
}

// MARK: Document packages

/// A document package a diff changed files inside: a folder the system
/// shows as one file, such as a `.horizontal` board, an `.rtfd`, or a
/// Keynote presentation saved as a package. Git keeps its files one by one,
/// so its diff is theirs; its picture is of the whole.
struct PackageChange: Identifiable, Hashable, Sendable {
    /// Where it is in the repository; empty when the repository itself is
    /// the package.
    var path: String
    /// Where it was on the old side, which differs when it was renamed.
    var oldPath: String
    /// Its name, such as `Board.horizontal`.
    var name: String
    var change: FileChange
    var oldSource: ContentSource?
    var newSource: ContentSource?
    /// The changed files inside it.
    var files: [String]

    var id: String { path }
}

enum DocumentPackages {
    private static let known = Mutex<[String: Bool]>([:])

    /// Whether a folder with this extension is a package, as the system's
    /// and installed apps' types say.
    static func isPackage(extension pathExtension: String) -> Bool {
        let key = pathExtension.lowercased()
        guard !key.isEmpty else { return false }
        if let answer = known.withLock({ $0[key] }) { return answer }
        // Asked as a package: the plain lookup assumes a file, and finds
        // nothing for an extension only a package type declares.
        let answer = UTType(filenameExtension: key, conformingTo: .package).map { !$0.isDynamic } ?? false
        known.withLock { $0[key] = answer }
        return answer
    }

    /// The outermost package a file is inside, as its path; `nil` when it is
    /// in none. Only the folders are looked at, not the file's own name.
    static func package(
        containing path: String, isPackage: (String) -> Bool = isPackage(extension:)
    ) -> String? {
        let folders = path.split(separator: "/", omittingEmptySubsequences: false).dropLast()
        var prefix: [Substring] = []
        for folder in folders {
            prefix.append(folder)
            let ext = (String(folder) as NSString).pathExtension
            if !ext.isEmpty, isPackage(ext) {
                return prefix.joined(separator: "/")
            }
        }
        return nil
    }

    /// The packages `files` change, each keyed by the first of its files in
    /// the list, where its picture goes. When the repository itself is a
    /// package, every file is in it.
    static func changes(
        in files: [FileDiff], repositoryName: String?, isPackage: (String) -> Bool = isPackage(extension:)
    ) -> [String: PackageChange] {
        let rootIsPackage = repositoryName.map { isPackage(($0 as NSString).pathExtension) } ?? false
        var order: [String] = []
        var members: [String: [FileDiff]] = [:]
        for file in files where file.submodule == nil {
            let found = rootIsPackage
                ? ""
                : package(containing: file.path, isPackage: isPackage)
                    ?? package(containing: file.oldPath, isPackage: isPackage)
            guard let found else { continue }
            if members[found] == nil { order.append(found) }
            members[found, default: []].append(file)
        }
        var changes: [String: PackageChange] = [:]
        for path in order {
            guard let inside = members[path], let first = inside.first else { continue }
            let oldPath = rootIsPackage ? "" : package(containing: first.oldPath, isPackage: isPackage) ?? path
            let change: FileChange
            if inside.allSatisfy({ $0.change == .added || $0.change == .untracked }) {
                change = .added
            } else if inside.allSatisfy({ $0.change == .deleted }) {
                change = .deleted
            } else if oldPath != path {
                change = .renamed
            } else {
                change = .modified
            }
            let name = path.isEmpty
                ? repositoryName ?? ""
                : String(path.split(separator: "/").last ?? Substring(path))
            changes[first.id] = PackageChange(
                path: path, oldPath: oldPath, name: name, change: change,
                oldSource: first.oldSource, newSource: first.newSource, files: inside.map(\.path)
            )
        }
        return changes
    }
}

extension EnvironmentValues {
    /// The document packages the diffs shown change, by the first changed
    /// file in each, which shows the package's picture above itself.
    @Entry var diffPackages: [String: PackageChange] = [:]
}

extension View {
    /// Shows a picture of each document package `files` change, above the
    /// first of its files.
    func diffPackages(_ files: [FileDiff]) -> some View {
        modifier(DiffPackagesModifier(files: files))
    }
}

private struct DiffPackagesModifier: ViewModifier {
    var files: [FileDiff]

    @Environment(\.diffRepository) private var repository

    func body(content: Content) -> some View {
        content.environment(
            \.diffPackages,
            DocumentPackages.changes(in: files, repositoryName: repository?.url.lastPathComponent)
        )
    }
}

// MARK: Showing files in Quick Look

/// A file or folder on one side of a comparison, to show in Quick Look or
/// drag out.
struct PreviewItem: Hashable, Sendable {
    var path: String
    var source: ContentSource
}

/// Shows files in the window's Quick Look panel, writing out first what is
/// not on disk as it was.
struct QuickLookPresenter {
    fileprivate var present: @MainActor ([URL], URL, PreviewFolder?) -> Void
    fileprivate var report: @MainActor (any Error) -> Void

    /// Shows the items as their sides have them, reporting what goes wrong.
    @MainActor func open(_ items: [PreviewItem], selected: Int = 0, in repository: Repository) {
        Task {
            do {
                try await show(items, selected: selected, in: repository)
            } catch {
                report(error)
            }
        }
    }

    /// Shows files already written; `folder` is kept until the panel closes.
    @MainActor func show(_ urls: [URL], selected: URL, keeping folder: PreviewFolder? = nil) {
        present(urls, selected, folder)
    }

    /// Writes out each item as its side has it, the working tree's in place,
    /// then shows them. Throws what writing one out threw.
    @MainActor func show(_ items: [PreviewItem], selected: Int = 0, in repository: Repository) async throws {
        let folder = try PreviewFolder()
        let repositoryName = repository.url.lastPathComponent
        var urls: [URL] = []
        for (position, item) in items.enumerated() {
            if item.source == .workingTree {
                urls.append(item.path.isEmpty ? repository.url : repository.url.appending(path: item.path))
                continue
            }
            let name = PreviewFiles.exportName(for: item.path, source: item.source, repositoryName: repositoryName)
            let url = folder.location(of: name, in: String(position))
            if try await repository.export(item.path, from: item.source, to: url, limit: PreviewFiles.sizeLimit) != nil {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        present(urls, urls[min(selected, urls.count - 1)], folder)
    }
}

extension PreviewFiles {
    /// The most written out for one preview or drag: a whole package, with
    /// every file in it.
    static let sizeLimit = 512 << 20
}

extension EnvironmentValues {
    /// Shows files in Quick Look, where a window has the panel.
    @Entry var quickLook: QuickLookPresenter?
}

extension View {
    /// What diffs read beyond their lines: the repository, for both sides of
    /// an image or a document package, and a Quick Look panel to show files
    /// in. A window sets it, and a sheet with diffs, which the window's does
    /// not reach.
    func diffSupport(_ model: RepositoryModel) -> some View {
        environment(\.diffRepository, model.repository)
            .quickLookPanel { model.report($0) }
    }

    /// The Quick Look panel for the files this window's views ask to show;
    /// `report` tells of a file that could not be written out for it.
    func quickLookPanel(report: @escaping @MainActor (any Error) -> Void) -> some View {
        modifier(QuickLookPanel(report: report))
    }
}

private struct QuickLookPanel: ViewModifier {
    var report: @MainActor (any Error) -> Void

    @State private var items: [URL] = []
    @State private var selection: URL?
    /// What the files shown were written into, kept while they show.
    @State private var folder: PreviewFolder?

    func body(content: Content) -> some View {
        content
            .environment(\.quickLook, QuickLookPresenter(present: { urls, selected, folder in
                self.folder = folder
                items = urls
                selection = selected
            }, report: report))
            .quickLookPreview($selection, in: items)
            .onChange(of: selection) {
                if selection == nil {
                    folder = nil
                    items = []
                }
            }
    }
}

extension DocumentPackages {
    /// Whether a path names a package by its extension, to offer Quick Look
    /// for a folder, which shows nothing worth seeing for a plain one.
    static func isPackage(path: String) -> Bool {
        isPackage(extension: (path as NSString).pathExtension)
    }
}

/// A file or package as Quick Look draws it, fitted to the space it is
/// given; `fallback` where Quick Look has no picture of it. Clicking the
/// picture opens it in the Quick Look panel.
struct QuickLookPicture<Fallback: View>: View {
    var item: PreviewItem
    var repository: Repository
    @ViewBuilder var fallback: Fallback

    @Environment(\.displayScale) private var displayScale
    @Environment(\.quickLook) private var quickLook
    @State private var picture: Picture?

    /// The size Quick Look is asked to draw at, in points.
    static var size: CGSize { CGSize(width: 1_400, height: 1_400) }

    private enum Picture {
        case drawn(Unchecked<CGImage>, url: URL, folder: PreviewFolder?)
        case unavailable
    }

    var body: some View {
        Group {
            switch picture {
            case .drawn(let image, let url, let folder):
                Image(decorative: image.value, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) {
                        quickLook?.show([url], selected: url, keeping: folder)
                    }
                    .help("Double-click to open in Quick Look")
            case .unavailable:
                fallback
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item) { await load() }
    }

    private func load() async {
        picture = nil
        let key = QuickLookTypes.key(for: item.path, isFolder: DocumentPackages.isPackage(path: item.path))
        guard !QuickLookTypes.hasNoPreview(key) else {
            picture = .unavailable
            return
        }
        let scale = displayScale
        do {
            let url: URL
            var folder: PreviewFolder?
            if item.source == .workingTree {
                url = item.path.isEmpty ? repository.url : repository.url.appending(path: item.path)
            } else {
                let made = try PreviewFolder()
                folder = made
                let name = PreviewFiles.fileName(for: item.path, repositoryName: repository.url.lastPathComponent)
                url = made.location(of: name, in: "Preview")
                guard try await repository.export(item.path, from: item.source, to: url, limit: PreviewFiles.sizeLimit) != nil else {
                    picture = .unavailable
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let image = await QuickLookThumbnail.make(for: url, size: Self.size, scale: scale)
            guard !Task.isCancelled else { return }
            guard let image else {
                QuickLookTypes.setHasNoPreview(key)
                picture = .unavailable
                return
            }
            picture = .drawn(Unchecked(image), url: url, folder: folder)
        } catch {
            picture = .unavailable
        }
    }
}

extension View {
    /// Space shows the selection in Quick Look, as in the Finder: `items`
    /// are what is selected, or empty to leave the key alone.
    func quickLookOnSpace(in repository: Repository, _ items: @escaping () -> [PreviewItem]) -> some View {
        modifier(QuickLookOnSpace(repository: repository, items: items))
    }
}

private struct QuickLookOnSpace: ViewModifier {
    var repository: Repository
    var items: () -> [PreviewItem]

    @Environment(\.quickLook) private var quickLook

    func body(content: Content) -> some View {
        content.onKeyPress(.space) {
            let items = items()
            guard let quickLook, !items.isEmpty else { return .ignored }
            quickLook.open(items, in: repository)
            return .handled
        }
    }
}

/// A Quick Look menu item or button for one file or package.
struct QuickLookButton: View {
    var item: PreviewItem
    var repository: Repository
    var title: LocalizedStringKey = "Quick Look"

    @Environment(\.quickLook) private var quickLook

    var body: some View {
        if let quickLook {
            Button(title, systemImage: "eye") {
                quickLook.open([item], in: repository)
            }
            .help("Show it in Quick Look")
        }
    }
}
