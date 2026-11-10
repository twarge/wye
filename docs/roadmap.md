# Roadmap

What Twig needs to be a complete git client, roughly in the order planned.
Tick an item when it lands on main.

## Remotes

- [x] Fetch, pull and push over HTTPS, with progress and cancellation.
- [x] Credentials: personal access tokens stored in the Keychain.
- [ ] SSH: keys generated or imported into the app and kept in the Keychain.
      libgit2 needs libssh2 and a crypto library for this; neither is built yet.
- [x] Clone, into a chosen folder on macOS and into Documents on iOS.
- [x] Add, rename and remove remotes; track a remote branch on checkout.
- [x] Pull by merge, rebase or fast-forward only, with autostash; sync;
      push to any remote and name; fetch options; relative remote URLs.
- [x] Delete and rename remote branches; open remotes and branches on the web.
- [ ] Hosting accounts (pull requests, repository lists).

## Working copy

- [x] Stage and unstage single hunks and lines.
- [x] Discard changes, with confirmation.
- [x] Amend the last commit.
- [x] Commit templates, subject length marker and recent messages.
- [x] Stash: save, apply, pop and drop.
- [x] Resolve merge conflicts.
- [x] Notice changes on disk and refresh without being asked.
- [ ] Image diffs; syntax colouring; side-by-side diffs.
- [x] Ignore files from their menu, edit the ignore rules; stop tracking and
      assume unchanged.
- [x] Folder tree, sorting and filtering of the changed files; file actions
      (open, Quick Look, reveal, rename, Trash, restore from a commit).
- [x] Diff options: context lines, ignoring whitespace, invisible characters,
      tab width, folding large commits.
- [ ] Git LFS.

## History

- [x] Search by message, author, hash and path.
- [x] File history and blame.
- [x] Browse the tree at a commit.
- [x] Compare two commits or branches.
- [x] Reflog.
- [x] Show diffs of a merge against each parent.
- [x] View options: graph, first parent only, date or topological order, grouping, row size.
- [x] Act on several commits; save a commit as a patch and apply a patch file.
- [x] Edit the last commit's message.

## Branching

- [x] Merge, rebase, cherry-pick and revert.
- [ ] Interactive rebase: reorder, squash, reword, drop.
- [x] Rename and delete branches; create and delete tags.
- [x] Publish tags.
- [x] Reset to a commit.
- [x] Group branches by folder in the sidebar.
- [ ] Submodules: update, add, remove. Worktrees: add, remove, open.
- [x] Undo and redo for the operations above, and for staging, stashes and discards.

## App

- [ ] App icon.
- [ ] Localisation with string catalogs.
- [x] Repository groups and search in the repository list.
- [x] Quick open; a full menu bar and keyboard shortcuts on macOS.
- [ ] Commit signing.
- [ ] App Store submission: privacy manifest, screenshots, review notes.

## Known limits

- Hooks do not run. A sandboxed app cannot run a repository's scripts.
- The user's own `~/.gitconfig` and SSH keys are outside the sandbox, so Twig
  keeps its own configuration and will keep its own keys.
- iOS has no recursive file watcher. Twig sees changes to git's own state
  and to the top two levels of the working tree as they happen; an edit
  deeper down, or one that rewrites a file in place, shows when Twig comes
  back to the front or after the next refresh.
- The first page of a very large history is slow, because the commits are
  sorted before any are shown.
