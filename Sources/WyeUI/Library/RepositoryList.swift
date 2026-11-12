import GitKit
import SwiftUI
import WyeShared

/// The repositories in their groups, filtered by a search and sorted.
/// Rows drag onto a group's header or onto another row to move into that
/// group; folders dragged in from outside are added, into the group they
/// are dropped on.
struct RepositoryList: View {
    var query: String
    var order: RepositoryListOrder
    var open: (RepositoryBookmark) -> Void
    /// Asks for a group's name: a new group with these repositories, or a rename.
    var nameGroup: (GroupNaming) -> Void

    @Environment(RepositoryLibrary.self) private var library
    @Environment(WindowActions.self) private var actions
    @Environment(\.scenePhase) private var scenePhase
    @State private var heads = RepositoryHeads()
    /// The watched folders folded shut, as their identifiers in one string.
    @AppStorage("repositoryList.collapsedFolders") private var collapsedFolders = ""

    var body: some View {
        let sections = self.sections
        let folders = self.folderEntries
        List {
            if query.isEmpty {
                FilesLocationOffer()
            }
            ForEach(sections) { section in
                if section.group == nil, !folders.isEmpty {
                    // Watched folders come after the groups, each a folder
                    // row that folds its repositories away.
                    Section {
                        ForEach(folders) { entry in
                            DisclosureGroup(isExpanded: isExpanded(entry.folder)) {
                                ForEach(entry.bookmarks) { bookmark in
                                    row(bookmark)
                                }
                            } label: {
                                WatchedFolderRow(
                                    name: entry.folder.name, path: library.path(of: entry.folder),
                                    count: entry.bookmarks.count
                                )
                                .contextMenu { folderMenu(entry.folder) }
                            }
                        }
                    }
                }
                Section {
                    ForEach(section.bookmarks) { bookmark in
                        row(bookmark)
                    }
                } header: {
                    if let group = section.group {
                        GroupHeader(name: group.name)
                            .dropDestination(for: URL.self) { urls, _ in drop(urls, into: group.id) }
                            .contextMenu {
                                Button("Rename Group…", systemImage: "pencil") { nameGroup(.rename(group)) }
                                Button("Delete Group", systemImage: "trash") { library.deleteGroup(group) }
                            }
                    } else if !library.groups.isEmpty || !folders.isEmpty,
                              !section.bookmarks.isEmpty || (query.isEmpty && !library.groups.isEmpty) {
                        GroupHeader(name: "Other Repositories")
                            .dropDestination(for: URL.self) { urls, _ in drop(urls, into: nil) }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: nil) }
        .overlay {
            if !query.isEmpty, sections.allSatisfy(\.bookmarks.isEmpty), folders.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: StatusKey(ids: library.listedBookmarks.map(\.id), isActive: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            await heads.load(library.listedBookmarks, from: library)
        }
    }

    /// What the branch and folder status depend on: which repositories are
    /// listed, read again when the app comes back to the front.
    private struct StatusKey: Hashable {
        var ids: [UUID]
        var isActive: Bool
    }

    private struct ListSection: Identifiable {
        var group: RepositoryGroup?
        var bookmarks: [RepositoryBookmark]
        var id: UUID? { group?.id }
    }

    /// Each group, then the repositories in none. While searching, groups
    /// with no match are left out; otherwise empty groups show, so there is
    /// somewhere to drop.
    private var sections: [ListSection] {
        let matching = library.listedBookmarks.filter(matches)
        var sections = library.groups.map { group in
            ListSection(group: group, bookmarks: order.sorted(matching.filter { $0.groupID == group.id }))
        }
        if !query.isEmpty {
            sections.removeAll { $0.bookmarks.isEmpty }
        }
        let others = matching.filter { !isGrouped($0) && !isInWatchedFolder($0) }
        sections.append(ListSection(group: nil, bookmarks: order.sorted(others)))
        return sections
    }

    private struct FolderEntry: Identifiable {
        var folder: WatchedFolder
        var bookmarks: [RepositoryBookmark]
        var id: UUID { folder.id }
    }

    /// Each watched folder with the repositories listed through it. One
    /// moved into a group shows in the group instead. While searching,
    /// folders with no match are left out.
    private var folderEntries: [FolderEntry] {
        let matching = library.listedBookmarks.filter { matches($0) && !isGrouped($0) }
        let entries = library.folders.map { folder in
            FolderEntry(folder: folder, bookmarks: order.sorted(matching.filter { $0.watchedFolder == folder.id }))
        }
        return query.isEmpty ? entries : entries.filter { !$0.bookmarks.isEmpty }
    }

    private func isGrouped(_ bookmark: RepositoryBookmark) -> Bool {
        library.group(of: bookmark) != nil
    }

    private func isInWatchedFolder(_ bookmark: RepositoryBookmark) -> Bool {
        bookmark.watchedFolder.map { id in library.folders.contains { $0.id == id } } ?? false
    }

    /// Open unless folded shut; always open while searching, so matches show.
    private func isExpanded(_ folder: WatchedFolder) -> Binding<Bool> {
        let id = folder.id.uuidString
        return Binding {
            !query.isEmpty || !collapsedFolders.contains(id)
        } set: { isExpanded in
            var collapsed = Set(collapsedFolders.split(separator: ",").map(String.init))
            if isExpanded { collapsed.remove(id) } else { collapsed.insert(id) }
            collapsedFolders = collapsed.sorted().joined(separator: ",")
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: WatchedFolder) -> some View {
        if Platform.canRevealFiles, let url = library.url(of: folder) {
            Button(Platform.revealInFileBrowserTitle, systemImage: "folder") {
                Platform.revealInFileBrowser(url)
            }
        }
        Button("Stop Watching", systemImage: "eye.slash", role: .destructive) {
            library.stopWatching(folder)
        }
    }

    private func matches(_ bookmark: RepositoryBookmark) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return bookmark.name.localizedStandardContains(query)
            || library.path(of: bookmark)?.localizedStandardContains(query) == true
            || heads.statuses[bookmark.id]?.branch?.localizedStandardContains(query) == true
    }

    private func row(_ bookmark: RepositoryBookmark) -> some View {
        Button {
            open(bookmark)
        } label: {
            RepositoryRow(
                name: bookmark.name, path: library.path(of: bookmark), status: heads.statuses[bookmark.id],
                summary: RepositoryStatusBoard.shared.summaries[bookmark.id]
            )
        }
        .buttonStyle(.plain)
        .pointerHover()
        .draggable(RepositoryDragReference.url(for: bookmark.id)) {
            Label(bookmark.name, systemImage: "folder")
                .padding(6)
        }
        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: bookmark.groupID) }
        .contextMenu {
            Button("Open", systemImage: "arrow.right.circle") { open(bookmark) }
            moveMenu(bookmark)
            if library.canMoveToFilesLocation(bookmark) {
                Button("Move to Files Location", systemImage: "folder.badge.gearshape") {
                    do {
                        try library.moveToFilesLocation(bookmark)
                    } catch {
                        actions.notices.post(error, during: "Move “\(bookmark.name)”")
                    }
                }
            }
            Divider()
            Button("Remove from Wye", systemImage: "minus.circle", role: .destructive) {
                library.remove(bookmark)
            }
        }
        .swipeActions {
            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                library.remove(bookmark)
            }
        }
    }

    private func moveMenu(_ bookmark: RepositoryBookmark) -> some View {
        Menu("Move to Group", systemImage: "folder.badge.plus") {
            ForEach(library.groups) { group in
                Button {
                    library.move([bookmark.id], to: group.id)
                } label: {
                    if library.group(of: bookmark)?.id == group.id {
                        Label(group.name, systemImage: "checkmark")
                    } else {
                        Text(group.name)
                    }
                }
            }
            if !library.groups.isEmpty {
                Divider()
                Button("No Group") { library.move([bookmark.id], to: nil) }
                    .disabled(library.group(of: bookmark) == nil)
            }
            Button("New Group…") { nameGroup(.new(moving: [bookmark.id])) }
        }
    }

    /// Moves dragged rows into a group, and adds dragged folders to it.
    @discardableResult
    private func drop(_ urls: [URL], into group: RepositoryGroup.ID?) -> Bool {
        let moved = urls.compactMap(RepositoryDragReference.id(from:))
        if !moved.isEmpty {
            library.move(moved, to: group)
        }
        let folders = urls.filter(\.isFileURL)
        if !folders.isEmpty {
            let added = actions.add(folders, to: library, opening: group == nil)
            if group != nil {
                library.move(added.map(\.id), to: group)
            }
        }
        // A link dragged from a browser or a message: the clone sheet,
        // filled in, for the user to say where it goes.
        let address = urls.lazy.filter { !$0.isFileURL && RepositoryDragReference.id(from: $0) == nil }
            .compactMap { RemoteAddressFinder.firstAddress(in: $0.absoluteString) }.first
        if let address, moved.isEmpty, folders.isEmpty {
            actions.cloneAddress = address
            actions.isCloning = true
        }
        return !moved.isEmpty || !folders.isEmpty || address != nil
    }
}

/// Asks for a group's name.
enum GroupNaming: Identifiable {
    /// A new group, with the repositories to move into it.
    case new(moving: [UUID])
    case rename(RepositoryGroup)

    var id: String {
        switch self {
        case .new: "new"
        case .rename(let group): group.id.uuidString
        }
    }
}

/// A repository row as a drag carries it: a URL of Wye's own, so drops
/// tell it apart from a folder dragged in to be added.
enum RepositoryDragReference {
    private static let scheme = "x-wye-repository"

    static func url(for id: UUID) -> URL {
        URL(string: "\(scheme):\(id.uuidString)")!
    }

    static func id(from url: URL) -> UUID? {
        guard url.scheme == scheme else { return nil }
        let text = url.absoluteString.dropFirst(scheme.count + 1)
        return UUID(uuidString: String(text))
    }
}

private struct GroupHeader: View {
    var name: String

    var body: some View {
        Text(name)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }
}

/// A watched folder, as the Finder would show one: its repositories fold
/// away beneath it.
private struct WatchedFolderRow: View {
    var name: String
    var path: String?
    var count: Int

    var body: some View {
        Label {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                    Text(path ?? "Folder not found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(count, format: .number)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("^[\(count) repository](inflect: true)")
            }
        } icon: {
            Image(systemName: path == nil ? "questionmark.folder" : "folder.fill")
                .foregroundStyle(path == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .help("Wye lists every repository in this folder")
    }
}

private struct RepositoryRow: View {
    var name: String
    var path: String?
    var status: RepositoryHeads.Status?
    var summary: RepositoryStatusSummary?

    var body: some View {
        Label {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                    Text(isMissing ? "Folder not found" : path ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let summary, !isMissing, summary.ahead > 0 || summary.behind > 0 {
                    AheadBehindBadge(ahead: summary.ahead, behind: summary.behind)
                }
                if let branch = status?.branch {
                    Label(branch, systemImage: status?.isDetached == true ? "smallcircle.filled.circle" : "arrow.triangle.branch")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(status?.isDetached == true ? "Detached HEAD" : "Current branch")
                }
            }
        } icon: {
            Image(systemName: isMissing ? "questionmark.folder" : "folder")
                .foregroundStyle(isMissing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var isMissing: Bool {
        path == nil || status == .missing
    }
}

/// Commits to push and to pull, as the toolbar's buttons count them.
private struct AheadBehindBadge: View {
    var ahead: Int
    var behind: Int

    var body: some View {
        HStack(spacing: 6) {
            if behind > 0 {
                Label("\(behind)", systemImage: "arrow.down")
            }
            if ahead > 0 {
                Label("\(ahead)", systemImage: "arrow.up")
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("^[\(behind) commit](inflect: true) to pull, ^[\(ahead) commit](inflect: true) to push")
        .help("Commits to pull and to push, as of the last fetch")
    }
}

/// Each listed repository's current branch, or that its folder is gone.
@MainActor
@Observable
final class RepositoryHeads {
    enum Status: Equatable, Sendable {
        case branch(String)
        case detached(String)
        case missing

        var branch: String? {
            switch self {
            case .branch(let name), .detached(let name): name
            case .missing: nil
            }
        }

        var isDetached: Bool {
            if case .detached = self { true } else { false }
        }
    }

    private(set) var statuses: [UUID: Status] = [:]

    /// Reads each repository's `HEAD`, and how it stands against its
    /// upstream, one at a time, off the main thread. What it learns goes on
    /// the status board too, for the rows' counts and the widgets.
    func load(_ bookmarks: [RepositoryBookmark], from library: RepositoryLibrary) async {
        RepositoryStatusBoard.shared.retain(Set(library.listedBookmarks.map(\.id)))
        for bookmark in bookmarks {
            guard !Task.isCancelled else { return }
            let status: Status
            do {
                let access = try library.access(to: bookmark)
                let read = await Self.status(at: access.url, id: bookmark.id, name: bookmark.name)
                // Held until the read is done: the folder is only open while it is.
                withExtendedLifetime(access) {}
                status = read.status
                if let summary = read.summary {
                    RepositoryStatusBoard.shared.record(summary)
                }
            } catch {
                status = .missing
            }
            statuses[bookmark.id] = status
        }
    }

    private nonisolated static func status(
        at url: URL, id: UUID, name: String
    ) async -> (status: Status, summary: RepositoryStatusSummary?) {
        await Task.detached(priority: .utility) { () -> (Status, RepositoryStatusSummary?) in
            guard Repository.exists(at: url), let repository = try? Repository(at: url),
                  let head = try? await repository.head() else { return (.missing, nil) }
            let status: Status = switch head {
            case .branch(let name, _), .unborn(let name):
                .branch(name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name)
            case .detached(let id): .detached(id.abbreviated())
            }
            let summary = try? await RepositoryStatusSummary.read(from: repository, id: id, name: name)
            return (status, summary)
        }.value
    }
}
