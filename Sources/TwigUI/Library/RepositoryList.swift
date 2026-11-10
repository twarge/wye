import GitKit
import SwiftUI

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

    var body: some View {
        let sections = self.sections
        List {
            ForEach(sections) { section in
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
                    } else if !library.groups.isEmpty, !section.bookmarks.isEmpty || query.isEmpty {
                        GroupHeader(name: "Other Repositories")
                            .dropDestination(for: URL.self) { urls, _ in drop(urls, into: nil) }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: nil) }
        .overlay {
            if !query.isEmpty, sections.allSatisfy(\.bookmarks.isEmpty) {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: StatusKey(ids: library.bookmarks.map(\.id), isActive: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            await heads.load(library.bookmarks, from: library)
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
        let matching = library.bookmarks.filter(matches)
        var sections = library.groups.map { group in
            ListSection(group: group, bookmarks: order.sorted(matching.filter { $0.groupID == group.id }))
        }
        if !query.isEmpty {
            sections.removeAll { $0.bookmarks.isEmpty }
        }
        let grouped = Set(library.groups.map(\.id))
        let others = matching.filter { $0.groupID.map { !grouped.contains($0) } ?? true }
        sections.append(ListSection(group: nil, bookmarks: order.sorted(others)))
        return sections
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
            RepositoryRow(name: bookmark.name, path: library.path(of: bookmark), status: heads.statuses[bookmark.id])
        }
        .buttonStyle(.plain)
        .draggable(RepositoryDragReference.url(for: bookmark.id)) {
            Label(bookmark.name, systemImage: "folder")
                .padding(6)
        }
        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: bookmark.groupID) }
        .contextMenu {
            Button("Open", systemImage: "arrow.right.circle") { open(bookmark) }
            moveMenu(bookmark)
            Divider()
            Button("Remove from Twig", systemImage: "minus.circle", role: .destructive) {
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
        return !moved.isEmpty || !folders.isEmpty
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

/// A repository row as a drag carries it: a URL of Twig's own, so drops
/// tell it apart from a folder dragged in to be added.
enum RepositoryDragReference {
    private static let scheme = "x-twig-repository"

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

private struct RepositoryRow: View {
    var name: String
    var path: String?
    var status: RepositoryHeads.Status?

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

    /// Reads each repository's `HEAD`, one at a time, off the main thread.
    func load(_ bookmarks: [RepositoryBookmark], from library: RepositoryLibrary) async {
        for bookmark in bookmarks {
            guard !Task.isCancelled else { return }
            let status: Status
            do {
                let access = try library.access(to: bookmark)
                status = await Self.status(at: access.url)
                // Held until the read is done: the folder is only open while it is.
                withExtendedLifetime(access) {}
            } catch {
                status = .missing
            }
            statuses[bookmark.id] = status
        }
    }

    private nonisolated static func status(at url: URL) async -> Status {
        await Task.detached(priority: .utility) { () -> Status in
            guard Repository.exists(at: url), let repository = try? Repository(at: url),
                  let head = try? await repository.head() else { return .missing }
            return switch head {
            case .branch(let name, _), .unborn(let name):
                .branch(name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name)
            case .detached(let id): .detached(id.abbreviated())
            }
        }.value
    }
}
