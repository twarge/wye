import Foundation
import GitKit

/// What a repository window shows, kept so that it opens the same way
/// again: the repository, what the sidebar selects, and the commit
/// selected in the history.
struct SavedWindow: Codable, Hashable {
    var repository: UUID
    var selection: SidebarItem?
    /// The commit's full hash.
    var commit: String?

    /// As scene storage keeps it.
    var encoded: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The selected commit, if its hash still reads as one.
    var commitID: OID? {
        commit.flatMap(OID.init(hex:))
    }
}

extension SavedWindow {
    init?(encoded: String?) {
        guard let data = encoded?.data(using: .utf8),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = saved
    }

    @MainActor
    init(_ model: RepositoryModel) {
        // One still waiting for its history to load is kept as it was.
        self.init(repository: model.id, selection: model.selection,
                  commit: (model.history.selection ?? model.commitToRestore)?.hex)
    }
}

/// Reopening windows the way they were left. Each window keeps its own
/// state in scene storage, which the system gives back when it restores
/// the window after Quit. A window that opens with nothing to restore and
/// no other window open, as after closing the last one and clicking the
/// app in the Dock, or after the system did not restore any, takes the
/// window last seen instead.
@MainActor
enum WindowRestoration {
    /// The repository windows open now.
    static var openWindows = 0

    private static let lastKey = "window.last"

    /// The repository window last changed, or the last one closed; `nil`
    /// when that window went back to the list of repositories.
    static var last: SavedWindow? {
        get { SavedWindow(encoded: UserDefaults.standard.string(forKey: lastKey)) }
        set {
            if let encoded = newValue?.encoded {
                UserDefaults.standard.set(encoded, forKey: lastKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastKey)
            }
        }
    }
}
