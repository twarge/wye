import Clibgit2
import Foundation

/// How an operation's record came out.
public enum UndoFinish: Sendable {
    case recorded(UndoRecord)
    /// The operation changed nothing a record covers.
    case unchanged
    /// The operation cannot be undone, for the reason given.
    case notUndoable(String)
}

extension Repository {
    // MARK: Recording

    /// Reads what an operation may change, before it runs. Never throws: an
    /// operation goes ahead even when it cannot be recorded, and
    /// `finishUndoable` then says why.
    public func beginUndoable(_ operation: UndoOperation) -> UndoStart {
        let checkpoint: Result<UndoCheckpoint, UndoError>
        do {
            checkpoint = .success(try undoCheckpoint(for: operation, keepingCommit: true))
        } catch let error as UndoError {
            checkpoint = .failure(error)
        } catch {
            checkpoint = .failure(.changedSince(error.localizedDescription))
        }
        return UndoStart(operation: operation, checkpoint: checkpoint)
    }

    /// Reads the repository again after the operation and records what it
    /// changed. An operation that stopped part way, on a conflict, is left
    /// to Abort rather than recorded.
    public func finishUndoable(_ start: UndoStart) -> UndoFinish {
        let before: UndoCheckpoint
        switch start.checkpoint {
        case .success(let checkpoint): before = checkpoint
        case .failure(let error): return .notUndoable(error.localizedDescription)
        }
        guard before.state == .clean else {
            return .notUndoable("It finished an operation that was already under way.")
        }
        let after: UndoCheckpoint
        do {
            after = try undoCheckpoint(for: start.operation, keepingCommit: false)
        } catch {
            return .notUndoable(error.localizedDescription)
        }
        guard after.state == .clean else {
            return .notUndoable("It stopped part way. Use Abort to return to where it started.")
        }
        guard let beforeHead = before.head, let afterHead = after.head else { return .unchanged }

        var refs: [String: UndoChange<OID?>] = [:]
        for name in Set(before.refs.keys).union(after.refs.keys) where before.refs[name] != after.refs[name] {
            refs[name] = UndoChange(before: before.refs[name], after: after.refs[name])
        }
        let changedRefs = !refs.isEmpty
        // Pin the branches HEAD is on, so that undo sees anything moving them.
        for head in [beforeHead, afterHead] {
            if case .symbolic(let name) = head, refs[name] == nil {
                refs[name] = UndoChange(before: before.refs[name], after: after.refs[name])
            }
        }
        var upstreams: [String: UndoChange<UndoUpstream>] = [:]
        for name in Set(before.upstreams.keys).union(after.upstreams.keys)
        where (before.upstreams[name] ?? UndoUpstream()) != (after.upstreams[name] ?? UndoUpstream()) {
            upstreams[name] = UndoChange(before: before.upstreams[name] ?? UndoUpstream(),
                                         after: after.upstreams[name] ?? UndoUpstream())
        }
        var working: UndoChange<UndoWorkingState>?
        if let old = before.working, let new = after.working, old.index != new.index || old.workTree != new.workTree {
            working = UndoChange(before: old, after: new)
        }
        var stash: UndoChange<[UndoStashEntry]>?
        if let old = before.stash, let new = after.stash, old != new {
            stash = UndoChange(before: old, after: new)
        }
        guard beforeHead != afterHead || changedRefs || !upstreams.isEmpty || working != nil || stash != nil else {
            return .unchanged
        }

        var rename: UndoChange<String>?
        if start.operation.kind == .renameBranch {
            let removed = refs.filter { $0.value.before != nil && $0.value.after == nil }.map(\.key)
            let added = refs.filter { $0.value.before == nil && $0.value.after != nil }.map(\.key)
            if removed.count == 1, added.count == 1 {
                rename = UndoChange(before: removed[0], after: added[0])
            }
        }
        return .recorded(UndoRecord(
            operation: start.operation, head: UndoChange(before: beforeHead, after: afterHead), refs: refs,
            upstreams: upstreams, working: working, stash: stash, rename: rename
        ))
    }

    // MARK: Undoing and redoing

    /// Checks that a record can be applied: the repository is still as the
    /// operation left it (for undo) or as undo left it (for redo), and
    /// everything it restores still exists. Throws `UndoError` saying what
    /// is in the way; asks for confirmation when it would take commits that
    /// have been pushed off a branch.
    public func undoPreflight(_ record: UndoRecord, _ direction: UndoDirection) throws -> UndoPreflight {
        _ = try undoPlan(record, direction)
        if let warning = try pushedCommitWarning(record, direction) {
            return .needsConfirmation(warning)
        }
        return .ready
    }

    /// Applies a record: undoes the operation, or does it again. Checks as
    /// `undoPreflight` does, apart from the confirmation, which is the
    /// caller's to have asked for.
    public func applyUndo(_ record: UndoRecord, _ direction: UndoDirection) throws {
        let plan = try undoPlan(record, direction)
        let log = "\(direction == .undo ? "undo" : "redo"): \(record.title)"
        let from = direction.from, to = direction.to

        if let workTree = plan.workTree {
            try restoreWorkTree(workTree)
        }
        if !plan.index.isEmpty {
            let index = try branchingIndex()
            defer { git_index_free(index) }
            for edit in plan.index {
                if let entry = edit.new {
                    try withIndexEntry(path: edit.path, entry) { _ = try check(git_index_add(index, $0)) }
                } else {
                    try check(git_index_remove(index, edit.path, 0))
                }
            }
            try check(git_index_write(index))
        }

        // A rename goes back as a rename, taking its reflog and settings along.
        var handled: Set<String> = []
        if let rename = record.rename {
            let source = rename.value(from), destination = rename.value(to)
            var reference: OpaquePointer?
            try check(git_reference_lookup(&reference, pointer, source))
            defer { git_reference_free(reference) }
            var moved: OpaquePointer?
            try check(git_branch_move(&moved, reference, shortBranchName(destination), 0))
            git_reference_free(moved)
            handled = [source, destination]
        }
        for (name, change) in record.refs where !handled.contains(name) {
            guard let target = change.value(to), change.value(from) != target else { continue }
            var oid = target.raw
            var reference: OpaquePointer?
            try check(git_reference_create(&reference, pointer, name, &oid, 1, log))
            git_reference_free(reference)
        }
        let head = record.head.value(to)
        if try currentUndoHead() != head {
            switch head {
            case .symbolic(let name):
                var reference: OpaquePointer?
                try check(git_reference_symbolic_create(&reference, pointer, "HEAD", name, 1, log))
                git_reference_free(reference)
            case .detached(let id):
                var oid = id.raw
                try check(git_repository_set_head_detached(pointer, &oid))
            }
        }
        for (name, change) in record.refs where !handled.contains(name) {
            guard change.value(to) == nil, change.value(from) != nil else { continue }
            var reference: OpaquePointer?
            try check(git_reference_lookup(&reference, pointer, name))
            defer { git_reference_free(reference) }
            try check(git_reference_delete(reference))
        }
        for (name, change) in record.upstreams {
            try writeUpstream(change.value(to), of: name)
        }
        if let stash = record.stash {
            try writeStashList(stash.value(to))
        }
    }

    // MARK: Checking

    /// What applying a record changes in the index and working tree, once
    /// everything it depends on has been checked.
    private struct UndoPlan {
        var index: [UndoDelta] = []
        var workTree: [UndoDelta]?
    }

    private func undoPlan(_ record: UndoRecord, _ direction: UndoDirection) throws -> UndoPlan {
        let from = direction.from, to = direction.to
        let state = RepositoryState(git_repository_state(pointer))
        guard state == .clean else { throw UndoError.operationInProgress(state) }

        let head = try currentUndoHead()
        if head != record.head.value(from) {
            throw UndoError.changedSince("\(describe(head)) is checked out now, not \(describe(record.head.value(from))).")
        }
        for (name, change) in record.refs.sorted(by: { $0.key < $1.key }) {
            guard try rawTarget(of: name) == change.value(from) else {
                let what = name.hasPrefix("refs/tags/") ? "The tag" : "The branch"
                let verb = change.value(from) == nil ? "has been created" : "has moved or been deleted"
                throw UndoError.changedSince("\(what) “\(shortName(of: name))” \(verb) since.")
            }
        }
        for (name, change) in record.upstreams {
            guard try readUpstream(of: name) == change.value(from) else {
                throw UndoError.changedSince("The upstream of “\(shortName(of: name))” has changed since.")
            }
        }
        if let stash = record.stash {
            guard try stashList().map(\.id) == stash.value(from).map(\.id) else {
                throw UndoError.changedSince("The stash list has changed since.")
            }
        }

        // Everything restored has to be there to restore.
        var needed = record.refs.values.compactMap { $0.value(to) }
        if case .detached(let id) = record.head.value(to) { needed.append(id) }
        if let working = record.working {
            needed.append(working.value(to).index)
            needed += [working.value(to).workTree, working.value(from).workTree].compactMap(\.self)
            needed.append(working.value(from).index)
        }
        needed += record.stash?.value(to).map(\.id) ?? []
        try requireObjects(needed)

        var plan = UndoPlan()
        guard let working = record.working else { return plan }
        let old = working.value(from), new = working.value(to)

        let index = try branchingIndex()
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) != 0 { throw UndoError.conflicts }
        plan.index = try treeDeltas(from: old.index, to: new.index)
        for delta in plan.index {
            let current = git_index_get_bypath(index, delta.path, 0).map { UndoEntry(id: OID($0.pointee.id), mode: $0.pointee.mode) }
            guard current == delta.old else {
                throw UndoError.changedSince("“\(delta.path)” has been staged or unstaged since.")
            }
        }

        if let oldTree = old.workTree, let newTree = new.workTree {
            guard let root = git_repository_workdir(pointer).map({ String(cString: $0) }) else {
                throw UndoError.noWorkingDirectory
            }
            let deltas = try treeDeltas(from: oldTree, to: newTree).filter { !$0.isSubmodule }
            for delta in deltas {
                guard try workTreeEntry(at: delta.path, root: root)?.ignoringExecutable == delta.old?.ignoringExecutable else {
                    throw UndoError.changedSince("“\(delta.path)” has changed since.")
                }
            }
            plan.workTree = deltas
        }
        return plan
    }

    /// How many commits, newest first, a record would take off a local
    /// branch that a remote branch already has.
    private func pushedCommitWarning(_ record: UndoRecord, _ direction: UndoDirection) throws -> String? {
        let remoteTips = try remoteBranchTips()
        guard !remoteTips.isEmpty else { return nil }
        for (name, change) in record.refs.sorted(by: { $0.key < $1.key }) where name.hasPrefix("refs/heads/") {
            guard let current = change.value(direction.from), let target = change.value(direction.to),
                  current != target else { continue }
            var walk: OpaquePointer?
            try check(git_revwalk_new(&walk, pointer))
            defer { git_revwalk_free(walk) }
            var push = current.raw, hide = target.raw
            try check(git_revwalk_push(walk, &push))
            // The target may be a tag object or gone from a branch: hide what it leads to.
            _ = git_revwalk_hide(walk, &hide)
            var oid = git_oid()
            var examined = 0
            while examined < 1_000, git_revwalk_next(&oid, walk) == 0 {
                examined += 1
                guard let remote = try remoteBranch(containing: OID(oid), among: remoteTips) else { continue }
                let summary = (try? commit(OID(oid)).summary) ?? OID(oid).abbreviated()
                let branch = shortName(of: name)
                return "“\(summary)” is already on \(remote). This takes it off “\(branch)” here only; "
                    + "taking it off \(remote) too would need a force push, which rewrites history others may have."
            }
        }
        return nil
    }

    private func remoteBranchTips() throws -> [(name: String, id: OID)] {
        var iterator: OpaquePointer?
        try check(git_reference_iterator_glob_new(&iterator, pointer, "refs/remotes/*"))
        defer { git_reference_iterator_free(iterator) }
        var tips: [(String, OID)] = []
        var reference: OpaquePointer?
        while git_reference_next(&reference, iterator) == 0 {
            defer { git_reference_free(reference) }
            guard git_reference_type(reference) == GIT_REFERENCE_DIRECT, let target = git_reference_target(reference) else {
                continue
            }
            tips.append((String(cString: git_reference_shorthand(reference)), OID(target)))
        }
        return tips
    }

    private func remoteBranch(containing id: OID, among tips: [(name: String, id: OID)]) throws -> String? {
        var commit = id.raw
        for tip in tips {
            if tip.id == id { return tip.name }
            var descendant = tip.id.raw
            if git_graph_descendant_of(pointer, &descendant, &commit) == 1 { return tip.name }
        }
        return nil
    }

    private func requireObjects(_ ids: [OID]) throws {
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, pointer))
        defer { git_odb_free(odb) }
        for id in ids {
            var oid = id.raw
            guard git_odb_exists(odb, &oid) == 1 else { throw UndoError.objectsMissing }
        }
    }

    private func describe(_ head: UndoHead) -> String {
        switch head {
        case .symbolic(let name): "“\(shortName(of: name))”"
        case .detached(let id): "the detached HEAD at \(id.abbreviated())"
        }
    }

    // MARK: Reading the state

    func undoCheckpoint(for operation: UndoOperation, keepingCommit: Bool) throws -> UndoCheckpoint {
        let refs = try localReferenceTargets()
        var upstreams: [String: UndoUpstream] = [:]
        for name in refs.keys where name.hasPrefix("refs/heads/") {
            let upstream = try readUpstream(of: name)
            if !upstream.isEmpty { upstreams[name] = upstream }
        }
        var checkpoint = UndoCheckpoint(
            state: RepositoryState(git_repository_state(pointer)), head: try currentUndoHead(), refs: refs,
            upstreams: upstreams, working: nil, stash: nil
        )
        let captures = operation.captures
        if captures.contains(.stash) {
            checkpoint.stash = try stashList()
        }
        if !captures.isDisjoint(with: [.index, .workTree, .untracked]) {
            guard checkpoint.state == .clean else { return checkpoint }
            checkpoint.working = try workingState(
                includingWorkTree: captures.contains(.workTree) || captures.contains(.untracked),
                untracked: captures.contains(.untracked) ? .some(operation.untrackedPaths) : nil,
                commitMessage: keepingCommit && keepsSnapshotCommit(operation) ? "Twig: before \(operation.title)" : nil
            )
        }
        return checkpoint
    }

    /// Operations whose undo brings back work that would otherwise be lost
    /// keep it as a commit too, which git can find by its name.
    private func keepsSnapshotCommit(_ operation: UndoOperation) -> Bool {
        operation.kind == .discard || (operation.kind == .reset && operation.captures.contains(.workTree))
            || operation.kind == .stashSave
    }

    func currentUndoHead() throws -> UndoHead {
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, "HEAD"))
        defer { git_reference_free(reference) }
        if git_reference_type(reference) == GIT_REFERENCE_SYMBOLIC, let target = git_reference_symbolic_target(reference) {
            return .symbolic(String(cString: target))
        }
        guard let target = git_reference_target(reference) else {
            throw GitError(code: GIT_ENOTFOUND.rawValue, message: "HEAD does not point at a commit.")
        }
        return .detached(OID(target))
    }

    /// Every local branch and tag, by full name, with what it points at
    /// directly: a commit, or for an annotated tag the tag object.
    private func localReferenceTargets() throws -> [String: OID] {
        var iterator: OpaquePointer?
        try check(git_reference_iterator_new(&iterator, pointer))
        defer { git_reference_iterator_free(iterator) }
        var targets: [String: OID] = [:]
        var reference: OpaquePointer?
        while git_reference_next(&reference, iterator) == 0 {
            defer { git_reference_free(reference) }
            let name = String(cString: git_reference_name(reference))
            guard name.hasPrefix("refs/heads/") || name.hasPrefix("refs/tags/"),
                  git_reference_type(reference) == GIT_REFERENCE_DIRECT,
                  let target = git_reference_target(reference) else { continue }
            targets[name] = OID(target)
        }
        return targets
    }

    private func rawTarget(of name: String) throws -> OID? {
        var reference: OpaquePointer?
        let code = git_reference_lookup(&reference, pointer, name)
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try check(code)
        defer { git_reference_free(reference) }
        return git_reference_target(reference).map { OID($0) }
    }

    private func shortBranchName(_ name: String) -> String {
        name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
    }

    // MARK: Upstreams

    private func readUpstream(of branch: String) throws -> UndoUpstream {
        var configuration: OpaquePointer?
        try check(git_repository_config_snapshot(&configuration, pointer))
        defer { git_config_free(configuration) }
        let short = shortBranchName(branch)
        return UndoUpstream(
            remote: GitEnvironment.string(for: "branch.\(short).remote", in: configuration),
            merge: GitEnvironment.string(for: "branch.\(short).merge", in: configuration)
        )
    }

    private func writeUpstream(_ upstream: UndoUpstream, of branch: String) throws {
        var configuration: OpaquePointer?
        try check(git_repository_config(&configuration, pointer))
        defer { git_config_free(configuration) }
        let short = shortBranchName(branch)
        for (key, value) in [("remote", upstream.remote), ("merge", upstream.merge)] {
            let name = "branch.\(short).\(key)"
            if let value {
                try check(git_config_set_string(configuration, name, value))
            } else {
                let code = git_config_delete_entry(configuration, name)
                if code != GIT_ENOTFOUND.rawValue { try check(code) }
            }
        }
    }

    // MARK: Stashes

    private func stashList() throws -> [UndoStashEntry] {
        let collected = StashEntries()
        let code = git_stash_foreach(pointer, { _, message, id, payload in
            guard let id, let payload else { return 0 }
            Unmanaged<StashEntries>.fromOpaque(payload).takeUnretainedValue().entries.append(
                UndoStashEntry(id: OID(id), message: message.map { String(cString: $0) } ?? "")
            )
            return 0
        }, Unmanaged.passUnretained(collected).toOpaque())
        if code == GIT_ENOTFOUND.rawValue { return [] }
        try check(code)
        return collected.entries
    }

    /// Makes the stash list exactly `entries`, newest first. The list is the
    /// reflog of `refs/stash`, so it is written out again entry by entry,
    /// each keeping its message and, where it is still listed, its date.
    private func writeStashList(_ entries: [UndoStashEntry]) throws {
        let name = "refs/stash"
        guard let top = entries.first else {
            var reference: OpaquePointer?
            if git_reference_lookup(&reference, pointer, name) == 0 {
                defer { git_reference_free(reference) }
                try check(git_reference_delete(reference))
            }
            let code = git_reflog_delete(pointer, name)
            if code != GIT_ENOTFOUND.rawValue { try check(code) }
            return
        }

        // Who stored each stash still listed, so its date survives.
        var committers: [OID: UnsafeMutablePointer<git_signature>] = [:]
        defer { committers.values.forEach { git_signature_free($0) } }
        var reflog: OpaquePointer?
        if git_reflog_read(&reflog, pointer, name) == 0 {
            for index in 0..<git_reflog_entrycount(reflog) {
                guard let entry = git_reflog_entry_byindex(reflog, index), let id = git_reflog_entry_id_new(entry),
                      let signature = git_reflog_entry_committer(entry) else { continue }
                var copy: UnsafeMutablePointer<git_signature>?
                if committers[OID(id)] == nil, git_signature_dup(&copy, signature) == 0, let copy {
                    committers[OID(id)] = copy
                }
            }
            git_reflog_free(reflog)
        }

        var oid = top.id.raw
        var reference: OpaquePointer?
        try check(git_reference_create(&reference, pointer, name, &oid, 1, top.message))
        git_reference_free(reference)

        try check(git_reflog_read(&reflog, pointer, name))
        defer { git_reflog_free(reflog) }
        while git_reflog_entrycount(reflog) > 0 {
            try check(git_reflog_drop(reflog, 0, 0))
        }
        for entry in entries.reversed() {
            var id = entry.id.raw
            if let committer = committers[entry.id] {
                try check(git_reflog_append(reflog, &id, committer, entry.message))
            } else {
                let commit = try lookupCommit(entry.id)
                defer { git_commit_free(commit) }
                try check(git_reflog_append(reflog, &id, git_commit_committer(commit), entry.message))
            }
        }
        try check(git_reflog_write(reflog))
    }

    // MARK: The working copy

    /// The index's tree and, when asked, a tree of the working tree: the
    /// index with each tracked file's working version, and the untracked
    /// files under `untracked` (every one for `.some(nil)`, none for `nil`).
    private func workingState(
        includingWorkTree: Bool, untracked: [String]??, commitMessage: String?
    ) throws -> UndoWorkingState {
        let index = try branchingIndex()
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) != 0 { throw UndoError.conflicts }
        var indexTree = git_oid()
        try check(git_index_write_tree(&indexTree, index))
        var state = UndoWorkingState(index: OID(indexTree), workTree: nil, commit: nil)
        guard includingWorkTree else { return state }
        guard let root = git_repository_workdir(pointer).map({ String(cString: $0) }) else {
            throw UndoError.noWorkingDirectory
        }

        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &indexTree))
        defer { git_tree_free(tree) }
        var snapshot: OpaquePointer?
        try check(git_index_new(&snapshot))
        defer { git_index_free(snapshot) }
        try check(git_index_read_tree(snapshot, tree))

        var options = git_status_options()
        try check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)))
        options.show = GIT_STATUS_SHOW_WORKDIR_ONLY
        options.flags = GIT_STATUS_OPT_EXCLUDE_SUBMODULES.rawValue
        if untracked != nil {
            options.flags |= GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
        }
        var list: OpaquePointer?
        try check(git_status_list_new(&list, pointer, &options))
        defer { git_status_list_free(list) }

        var untrackedBytes = 0
        for position in 0..<git_status_list_entrycount(list) {
            guard let entry = git_status_byindex(list, position)?.pointee,
                  let delta = entry.index_to_workdir?.pointee,
                  let rawPath = delta.new_file.path ?? delta.old_file.path else { continue }
            let path = String(cString: rawPath)
            let status = entry.status.rawValue
            if status & GIT_STATUS_WT_DELETED.rawValue != 0 {
                try check(git_index_remove(snapshot, path, 0))
                continue
            }
            if status & GIT_STATUS_WT_NEW.rawValue != 0 {
                guard let paths = untracked, Self.path(path, isIn: paths) else { continue }
                guard let size = Self.plainFileSize(root + path), size <= Self.largestKeptFile,
                      untrackedBytes + size <= Self.mostKeptUntracked else {
                    throw UndoError.cannotKeepCopy(path: path)
                }
                untrackedBytes += size
            } else if status & (GIT_STATUS_WT_MODIFIED.rawValue | GIT_STATUS_WT_TYPECHANGE.rawValue) == 0 {
                continue
            }
            guard let entry = try workTreeEntry(at: path, root: root) else { continue }
            try withIndexEntry(path: path, entry) { _ = try check(git_index_add(snapshot, $0)) }
        }
        var workTree = git_oid()
        try check(git_index_write_tree_to(&workTree, snapshot, pointer))
        state.workTree = OID(workTree)

        if let commitMessage, OID(workTree) != OID(indexTree) {
            state.commit = try snapshotCommit(tree: OID(workTree), message: commitMessage)
        }
        return state
    }

    /// The largest untracked file, and the most untracked bytes in all, an
    /// undo keeps a copy of.
    private static let largestKeptFile = 64 << 20
    private static let mostKeptUntracked = 256 << 20

    private static func path(_ path: String, isIn paths: [String]?) -> Bool {
        guard let paths else { return true }
        return paths.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    private static func plainFileSize(_ path: String) -> Int? {
        var information = stat()
        guard lstat(path, &information) == 0 else { return nil }
        let type = information.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFLNK else { return nil }
        return Int(information.st_size)
    }

    /// A commit of the saved working tree, on top of `HEAD`, referenced by
    /// nothing. `nil` without an identity to make it as.
    private func snapshotCommit(tree id: OID, message: String) throws -> OID? {
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0 else { return nil }
        defer { git_signature_free(signature) }
        var treeID = id.raw
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &treeID))
        defer { git_tree_free(tree) }
        var parents: [OpaquePointer?] = []
        if let head = try headCommit() { parents.append(head) }
        defer { parents.forEach { git_commit_free($0) } }
        var commit = git_oid()
        try check(git_commit_create(&commit, pointer, nil, signature, signature, nil, message + "\n", tree,
                                    parents.count, &parents))
        return OID(commit)
    }

    /// The file at `path` as git would record it, its contents written to
    /// the object database; `nil` when there is none, or a folder.
    private func workTreeEntry(at path: String, root: String) throws -> UndoEntry? {
        var information = stat()
        guard lstat(root + path, &information) == 0 else { return nil }
        let type = information.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFLNK else { return nil }
        var id = git_oid()
        try check(git_blob_create_from_workdir(&id, pointer, path))
        let mode: UInt32 = type == S_IFLNK ? 0o120000 : (information.st_mode & S_IXUSR != 0 ? 0o100755 : 0o100644)
        return UndoEntry(id: OID(id), mode: mode)
    }

    /// Writes the working tree's side of a plan: removes what the target
    /// lacks, then checks out the rest from the target tree, which applies
    /// the same filters a checkout does. The index is left to the caller.
    private func restoreWorkTree(_ deltas: [UndoDelta]) throws {
        guard let root = git_repository_workdir(pointer).map({ String(cString: $0) }) else {
            throw UndoError.noWorkingDirectory
        }
        let rootURL = URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL
        for delta in deltas where delta.new == nil {
            let file = rootURL.appending(path: delta.path)
            try FileManager.default.removeItem(at: file)
            removeEmptyFolders(above: file, upTo: rootURL)
        }
        let writes = deltas.filter { $0.new != nil }
        guard !writes.isEmpty, let target = writes.first?.newTree else { return }
        var treeID = target.raw
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &treeID))
        defer { git_tree_free(tree) }
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DONT_UPDATE_INDEX.rawValue
            | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
        try withStringArray(writes.map(\.path)) { paths in
            options.paths = paths
            _ = try check(git_checkout_tree(pointer, tree, &options))
        }
    }

    private func removeEmptyFolders(above file: URL, upTo root: URL) {
        var folder = file.deletingLastPathComponent().standardizedFileURL
        while folder.path.count > root.path.count, folder.path.hasPrefix(root.path) {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  contents.isEmpty,
                  (try? FileManager.default.removeItem(at: folder)) != nil else { return }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// The files that differ between two trees, each with its entry on
    /// either side.
    private func treeDeltas(from old: OID, to new: OID) throws -> [UndoDelta] {
        guard old != new else { return [] }
        var oldID = old.raw, newID = new.raw
        var oldTree: OpaquePointer?, newTree: OpaquePointer?
        try check(git_tree_lookup(&oldTree, pointer, &oldID))
        defer { git_tree_free(oldTree) }
        try check(git_tree_lookup(&newTree, pointer, &newID))
        defer { git_tree_free(newTree) }
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, pointer, oldTree, newTree, nil))
        defer { git_diff_free(diff) }

        var byPath: [String: UndoDelta] = [:]
        var order: [String] = []
        for position in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, position)?.pointee,
                  let rawPath = delta.new_file.path ?? delta.old_file.path else { continue }
            let path = String(cString: rawPath)
            let oldEntry = delta.status == GIT_DELTA_ADDED
                ? nil : UndoEntry(id: OID(delta.old_file.id), mode: UInt32(delta.old_file.mode))
            let newEntry = delta.status == GIT_DELTA_DELETED
                ? nil : UndoEntry(id: OID(delta.new_file.id), mode: UInt32(delta.new_file.mode))
            // A change of type arrives as a removal and an addition.
            if var existing = byPath[path] {
                existing.old = existing.old ?? oldEntry
                existing.new = existing.new ?? newEntry
                byPath[path] = existing
            } else {
                byPath[path] = UndoDelta(path: path, old: oldEntry, new: newEntry, newTree: new)
                order.append(path)
            }
        }
        return order.compactMap { byPath[$0] }
    }

    private func withIndexEntry(path: String, _ entry: UndoEntry, _ body: (UnsafePointer<git_index_entry>) throws -> Void) throws {
        try path.withCString { cPath in
            var indexEntry = git_index_entry()
            indexEntry.mode = entry.mode
            indexEntry.id = entry.id.raw
            indexEntry.path = cPath
            try withUnsafePointer(to: &indexEntry) { try body($0) }
        }
    }
}

/// A file's object and mode in a tree or the index.
struct UndoEntry: Hashable {
    var id: OID
    var mode: UInt32

    var isSubmodule: Bool { mode == 0o160000 }

    /// The working tree check compares contents and links, not the
    /// executable bit, which some volumes do not keep.
    var ignoringExecutable: UndoEntry {
        mode == 0o100755 ? UndoEntry(id: id, mode: 0o100644) : self
    }
}

/// One path that differs between two trees.
struct UndoDelta {
    var path: String
    var old: UndoEntry?
    var new: UndoEntry?
    /// The tree the new side comes from.
    var newTree: OID

    var isSubmodule: Bool { old?.isSubmodule == true || new?.isSubmodule == true }
}

/// Gathers stash entries from a C callback, which cannot capture Swift state.
private final class StashEntries {
    var entries: [UndoStashEntry] = []
}
