# Plan

How Wye gets from its first version to a complete git client for macOS and
iOS. [roadmap.md](roadmap.md) is the checklist; this says how each piece
should work and how the work is divided.

## Ground rules

These hold for every feature.

- **One codebase.** Interface code is SwiftUI, written once for macOS and iOS.
  A platform difference goes in `Sources/WyeUI/Support/Platform.swift`, not
  in an `#if` scattered through a view.
- **Two layers.** `GitKit` is the engine: a Swift API over libgit2 with value
  types that are `Sendable`, no interface code, and every operation a method on
  the `Repository` actor. `WyeUI` never imports `Clibgit2`.
- **Sandbox first.** No command line git, no hooks, no reading `~/.gitconfig`
  or `~/.ssh`. Secrets live in the Keychain. Anything that cannot work in the
  App Store sandbox on both platforms is not built.
- **Initialize before calling libgit2.** Any GitKit entry point that is not a
  method of an open `Repository` calls `GitEnvironment.ensureInitialized()`
  first. Calling libgit2 before that corrupts the calling thread.
- **Tests check against git itself.** Each engine feature gets tests in
  `Tests/GitKitTests` that build a fixture with the command line git and
  compare GitKit's result with git's. `swift test` must pass.
- **Destructive actions confirm.** Anything that discards work (discard,
  reset --hard, force push, deleting an unmerged branch, dropping a stash)
  asks first and says what will be lost.
- **Errors are shown, never swallowed.** Operations go through
  `RepositoryModel.perform`, which shows the error and refreshes.
- **Style.** Swift 6 language mode, no warnings. `@Observable` models on the
  main actor, small views, comments that say why. Match the code that is there.

## 1. Remotes

The engine gets `Repository+Remotes.swift`.

- **Fetch** one remote or all, pruning deleted branches. Reports progress
  (objects received / total, bytes) through an `AsyncStream` and can be
  cancelled.
- **Pull** is fetch, then fast-forward when possible, otherwise merge (or
  rebase, per a setting). A pull that needs a merge with conflicts leaves the
  repository in the merging state for the working copy to resolve.
- **Push** the current branch to its upstream, setting one on first push
  ("publish"). Force push is a separate, confirmed action that uses
  force-with-lease semantics: it refuses if the remote moved since the last fetch.
- **Clone** from a URL into a chosen folder (macOS) or Wye's location in the Files app (iOS), with
  progress, then opens the result.
- **Credentials.** libgit2 asks through a callback. HTTPS uses a username and
  personal access token stored in the Keychain per host; a failed attempt
  prompts and offers to save. SSH is a later step: it needs libssh2 and a
  crypto library built from source, and keys kept in the Keychain.
- **Remote management.** Add, rename, remove, change URL. Checking out a
  remote branch creates a local branch that tracks it.

Interface: Fetch, Pull and Push buttons in the repository toolbar with badges
for ahead/behind; an activity indicator with the current operation and a
cancel button; a Clone sheet from the repository list; a credentials prompt;
an Accounts section in Settings listing saved hosts.

## 2. Working copy

- **Hunk and line staging.** The diff view gets a stage/unstage control on
  each hunk, and line selection to stage only some lines. The engine builds a
  patch for the selection and applies it to the index
  (`git_apply` with the index as the location).
- **Discard** a file, a hunk or everything, with confirmation. Untracked files
  go to the Trash where the platform has one.
- **Amend** the last commit: a toggle in the composer that loads the previous
  message and replaces the commit.
- **Stash.** Save (with message, optionally including untracked files, or
  keeping the index), apply, pop and drop. The Stashes list gets these as
  swipe and context actions.
- **Conflicts.** Conflicted files are grouped at the top with "use ours",
  "use theirs" and "mark resolved". A banner shows the operation under way
  (merge, rebase, cherry-pick, revert) with Continue and Abort.
- **Commit message help.** A soft limit marker on the subject, and the
  previous messages as history.
- Later: image diffs, syntax colouring, side-by-side diffs, ignore editing,
  LFS.

## 3. Branching

The engine gets `Repository+Merge.swift` and grows `Repository+Branches.swift`.

- **Merge** a branch into the current one: fast-forward, merge commit, or
  squash, chosen in a sheet. Conflicts hand over to the working copy.
- **Rebase** the current branch onto another, stopping on conflicts with
  Continue, Skip and Abort. Interactive rebase (reorder, squash, reword, drop)
  comes after plain rebase works.
- **Cherry-pick** and **revert** one or more commits from the history.
- **Reset** the current branch to a commit: soft, mixed or hard, hard confirmed.
- **Branches.** Rename, delete (refusing an unmerged branch unless forced and
  confirmed), set or clear upstream. **Tags.** Create lightweight or annotated
  at a commit, delete.
- **Checkout** a commit (detached) or a tag.
- **Sidebar.** Branch names with slashes group into folders. Context menus on
  branches, tags and remote branches carry these actions; so does a context
  menu on commits in the history.
- Later: submodule and worktree actions, undo.

## 4. History

- **Search** the history by message, author, hash and changed path, from a
  search field on the history list. Results keep the list's order.
- **File history.** The commits that touched a path, following renames.
- **Blame.** A file with each line's commit, author and date; selecting a line
  shows that commit.
- **Tree.** Browse the files at a commit and view one; the commit detail gets
  a Changes / Files switch.
- **Compare** two commits or branches: commits unique to each side and the diff.
- **Reflog** for `HEAD` and for a branch, as a sidebar entry.
- **Merge commits** show the diff against each parent.

## 5. App

- Notice changes on disk and refresh without being asked.
- App icon.
- Localisation with string catalogs.
- A full menu bar and keyboard shortcuts on macOS; quick open.
- Repository groups and search in the repository list.
- Commit signing.
- App Store submission: privacy manifest, screenshots, review notes.

## How the work is divided

Areas 1 to 4 are built side by side, each by its own worker, in the same
checkout. To keep them out of each other's way:

- Each area **adds its own files** and owns them. Engine work goes in new
  `Repository+<Area>.swift` files; model work in new
  `RepositoryModel+<Area>.swift` extensions; views in the area's own folder.
- Shared files (`RepositoryModel.swift`, `RepositoryView.swift`,
  `SidebarView.swift`, `HistoryView.swift`, `CommitDetailView.swift`,
  `FileDiffView.swift`, `Models.swift`, `Package.swift`) take only small,
  additive edits: a stored property, a toolbar item, one modifier. Read the
  file again immediately before editing it. Never reformat or reorganize one.
- Who owns which shared file's larger changes: `SidebarView.swift` belongs to
  Branching; `HistoryView.swift` and `CommitDetailView.swift` to History;
  `WorkingCopyView.swift`, `StashListView.swift` and `FileDiffView.swift` to
  Working copy; the toolbar in `RepositoryView.swift`, the repository list and
  Settings to Remotes.
- Each worker builds into its own directory
  (`swift build --scratch-path .build/<area>`), so builds do not collide. A
  compile error in a file another area owns is that area mid-change: wait and
  build again, do not fix it.
- Nobody commits, switches branches, or touches `Vendor/libgit2`.

Area 5 follows once these are in, since it touches every file.
