import GitKit
import SwiftUI
import WyeShared

/// The repositories in their groups, filtered by a search and sorted, each
/// with what wants looking at in it: its row says what is not committed or
/// pushed, what there is to pull, which checks failed and what waits for
/// review, and folds the particulars away beneath it. Rows drag onto a
/// group's header or onto another row to move into that group; folders
/// dragged in from outside are added, into the group they are dropped on.
struct RepositoryList: View {
    var query: String
    var order: RepositoryListOrder
    var open: (RepositoryBookmark) -> Void
    /// Asks for a group's name: a new group with these repositories, or a rename.
    var nameGroup: (GroupNaming) -> Void

    @Environment(RepositoryLibrary.self) private var library
    @Environment(WindowActions.self) private var actions
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ReviewModel
    /// The watched folders folded shut, as their identifiers in one string.
    @AppStorage("repositoryList.collapsedFolders") private var collapsedFolders = ""
    private var captions: ReviewCaptions { .shared }
    private var expansion: ReviewExpansion { .shared }
    private var accountChanges: AccountChangeCounter { .shared }

    /// - Parameter model: What reads the repositories and asks their
    ///   services; a test gives one whose services are recorded answers.
    init(
        query: String, order: RepositoryListOrder, open: @escaping (RepositoryBookmark) -> Void,
        nameGroup: @escaping (GroupNaming) -> Void, model: ReviewModel = ReviewModel(board: .shared)
    ) {
        self.query = query
        self.order = order
        self.open = open
        self.nameGroup = nameGroup
        _model = State(initialValue: model)
    }

    var body: some View {
        let sections = self.sections
        let folders = self.folderEntries
        // Read here so the rows fold and open as it changes.
        let _ = expansion.expanded
        List {
            if query.isEmpty {
                FilesLocationOffer()
                if let totals {
                    Section {
                        ReviewTotalsRow(totals: totals)
                    }
                }
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
        // The services are asked again too, whatever they said lately.
        .refreshable { await model.load(library.listedBookmarks, from: library, asksAgain: true) }
        .task(id: StatusKey(
            ids: library.listedBookmarks.map(\.id), isActive: scenePhase == .active, accounts: accountChanges.count
        )) {
            guard scenePhase == .active else { return }
            model.accountsChanged(to: accountChanges.count)
            await model.load(library.listedBookmarks, from: library)
        }
        .onChange(of: model.notice) {
            // Said in the window's strip, with everything else.
            guard let notice = model.notice else { return }
            actions.notices.post(notice)
            model.notice = nil
        }
        .onChange(of: library.listedBookmarks.map(\.id), initial: true) { _, ids in
            captions.retain(Set(ids))
        }
    }

    /// What every repository's reading depends on: which repositories are
    /// listed, read again when the app comes back to the front or an
    /// account is added or removed.
    private struct StatusKey: Hashable {
        var ids: [UUID]
        var isActive: Bool
        var accounts: Int
    }

    /// What the list totals at its top: what wants looking at, or, once
    /// every repository has been read, that nothing does. Nothing while
    /// that is not known yet, or with no repository to say it of.
    private var totals: ReviewTotals? {
        let totals = ReviewTotals(Array(model.reviews.values))
        if totals.repositories > 0 { return totals }
        return model.hasLoaded && !library.listedBookmarks.isEmpty ? totals : nil
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

    /// Whether the search names the repository, its folder, its branch, or
    /// something its row folds away: a changed file, a commit, a pull request.
    private func matches(_ bookmark: RepositoryBookmark) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return bookmark.name.localizedStandardContains(query)
            || library.path(of: bookmark)?.localizedStandardContains(query) == true
            || model.reviews[bookmark.id]?.matches(query) == true
    }

    /// A repository's row, over what it folds away when there is anything
    /// to look at.
    @ViewBuilder
    private func row(_ bookmark: RepositoryBookmark) -> some View {
        let review = model.reviews[bookmark.id]
        if let review, review.needsAttention {
            DisclosureGroup(isExpanded: isExpanded(review)) {
                ReviewWork(review: review) { open(bookmark) }
            } label: {
                label(bookmark, review: review)
            }
        } else {
            label(bookmark, review: review)
        }
    }

    /// Folded shut unless opened, or a search found something inside.
    private func isExpanded(_ review: RepositoryReview) -> Binding<Bool> {
        Binding {
            review.hasFoldedMatch(for: query) || expansion.expanded.contains(review.id)
        } set: { isExpanded in
            if isExpanded {
                expansion.expanded.insert(review.id)
            } else {
                expansion.expanded.remove(review.id)
            }
        }
    }

    private func label(_ bookmark: RepositoryBookmark, review: RepositoryReview?) -> some View {
        RepositoryRow(
            name: bookmark.name, path: library.path(of: bookmark), review: review,
            isMissing: model.missing.contains(bookmark.id), caption: captions.caption(for: bookmark.id),
            isPushing: model.pushing.contains(bookmark.id),
            open: { open(bookmark) }, push: { Task { await model.push(bookmark, in: library) } }
        )
        // Only for rows the list shows, and again when the changes change.
        // One with no work left drops the caption it had.
        .task(id: review) {
            if let review { await captions.describe(review, in: library) }
        }
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

/// An icon close before its title, within a line of text. A list's own
/// label keeps a column for its icon, which on an iPhone leaves a branch's
/// name little room beside the repository's and the push button.
private struct InlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// A repository: its name and where `HEAD` is, its folder, and, when there
/// is something to look at, what that comes to and what the on-device model
/// says its work is about. The row opens the repository; the button at the
/// end of its first line pushes.
private struct RepositoryRow: View {
    var name: String
    var path: String?
    /// What was read of it; `nil` until it is read, and when it cannot be.
    var review: RepositoryReview?
    /// Whether its folder is gone.
    var isMissing: Bool
    var caption: String?
    var isPushing: Bool
    var open: () -> Void
    var push: () -> Void

    var body: some View {
        Button(action: open) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(name)
                                .font(.headline)
                            if !isGone { head }
                        }
                        Spacer(minLength: 0)
                        if let review, !isGone {
                            marks(review)
                            // Room on the first line for the button laid
                            // over the row: one button cannot hold another,
                            // and beside the row it would narrow every line.
                            pushControl(review).hidden()
                        }
                    }
                    Text(isGone ? "Folder not found" : path ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let review, review.needsAttention, !isGone {
                        Text(review.summary)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let caption, !isGone {
                        Label(caption, systemImage: "sparkles")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help("Written on this device by Apple Intelligence")
                            .transition(.opacity)
                    }
                }
                .animation(.default, value: caption)
            } icon: {
                Image(systemName: isGone ? "questionmark.folder" : "folder")
                    .foregroundStyle(isGone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerHover()
        .overlay(alignment: .topTrailing) {
            if let review, !isGone { pushControl(review) }
        }
        .padding(.vertical, 4)
    }

    /// Pushes the checked-out branch's commits, or publishes the branch;
    /// a spinner while it does. Nothing where there is nothing to push.
    @ViewBuilder
    private func pushControl(_ review: RepositoryReview) -> some View {
        if isPushing {
            ProgressView().controlSize(.small)
        } else if review.ahead > 0 || review.isUnpublished {
            Button(action: push) {
                Label(review.isUnpublished ? "Publish" : "Push \(review.ahead)", systemImage: "arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(review.isUnpublished ? "Publish this branch to its remote" : "Push these commits to \(review.upstream ?? "the remote")")
        }
    }

    private var isGone: Bool {
        path == nil || isMissing
    }

    /// Where `HEAD` is: the checked-out branch, or the commit it is detached at.
    @ViewBuilder
    private var head: some View {
        if let name = review?.branch ?? review?.detachedAt {
            let isDetached = review?.branch == nil
            Label(name, systemImage: isDetached ? "smallcircle.filled.circle" : "arrow.triangle.branch")
                .labelStyle(InlineLabelStyle())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(isDetached ? "Detached HEAD" : "Current branch")
        }
    }

    /// What stands out at the row's end: that checks failed, and how many
    /// commits there are to pull. The commits to push are on the button.
    @ViewBuilder
    private func marks(_ review: RepositoryReview) -> some View {
        if let first = review.failedChecks.first {
            let branches = review.failedChecks.count == 1 ? "“\(first.branch)”" : "\(review.failedChecks.count) branches"
            Image(systemName: CheckStatus.failure.symbol)
                .foregroundStyle(CheckStatus.failure.color)
                .accessibilityLabel("Checks failed on \(branches)")
                .help("Checks failed on \(branches)")
        }
        if review.behind > 0 {
            Label("\(review.behind)", systemImage: "arrow.down")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("^[\(review.behind) commit](inflect: true) to pull")
                .help("Commits to pull, as of the last fetch")
        }
    }
}
