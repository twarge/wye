import Clibgit2
import Foundation

extension Repository {
    /// Throws away the unstaged changes to each path: a tracked file returns
    /// to its staged version, and an untracked file is removed. Staged
    /// changes are kept.
    public func discardChanges(in paths: [String], untracked: UntrackedRemoval = .trash) throws {
        guard !paths.isEmpty else { return }
        guard let workingDirectory = git_repository_workdir(pointer).map({ String(cString: $0) }) else {
            throw RepositoryError.noWorkingDirectory
        }

        var tracked: [String] = []
        var untrackedPaths: [String] = []
        for path in paths {
            var flags: UInt32 = 0
            let code = git_status_file(&flags, pointer, path)
            // A path git no longer knows about has nothing left to discard.
            if code == GIT_ENOTFOUND.rawValue { continue }
            try check(code)
            if flags & GIT_STATUS_CONFLICTED.rawValue != 0 {
                throw WorkingCopyError.conflicted(path: path)
            }
            if flags & GIT_STATUS_WT_NEW.rawValue != 0 {
                untrackedPaths.append(path)
            } else if flags & (GIT_STATUS_WT_MODIFIED.rawValue | GIT_STATUS_WT_DELETED.rawValue
                | GIT_STATUS_WT_TYPECHANGE.rawValue | GIT_STATUS_WT_RENAMED.rawValue) != 0 {
                tracked.append(path)
            }
        }

        if !tracked.isEmpty {
            var index: OpaquePointer?
            try check(git_repository_index(&index, pointer))
            defer { git_index_free(index) }
            try check(git_index_read(index, 0))

            var options = git_checkout_options()
            try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
            options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
            try withStringArray(tracked) { paths in
                options.paths = paths
                _ = try check(git_checkout_index(pointer, index, &options))
            }
        }

        let root = URL(filePath: workingDirectory, directoryHint: .isDirectory).standardizedFileURL
        for path in untrackedPaths {
            let file = root.appending(path: path)
            try remove(file, untracked)
            removeEmptyFolders(above: file, upTo: root)
        }
    }

    /// Throws away every unstaged change in the working copy, including
    /// untracked files. Conflicted files are left for resolving.
    public func discardAllChanges(untracked: UntrackedRemoval = .trash) throws {
        let paths = try status().filter { $0.unstaged != nil && !$0.isConflicted }.map(\.path)
        try discardChanges(in: paths, untracked: untracked)
    }

    private func remove(_ file: URL, _ removal: UntrackedRemoval) throws {
        if removal == .trash, (try? FileManager.default.trashItem(at: file, resultingItemURL: nil)) != nil {
            return
        }
        try FileManager.default.removeItem(at: file)
    }

    /// git does not track folders, so an untracked file's folder is gone from
    /// git's view once the file is. Removing it too leaves no empty husk.
    private func removeEmptyFolders(above file: URL, upTo root: URL) {
        var folder = file.deletingLastPathComponent().standardizedFileURL
        while folder.path.count > root.path.count, folder.path.hasPrefix(root.path) {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  contents.isEmpty,
                  (try? FileManager.default.removeItem(at: folder)) != nil else { return }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
    }
}
