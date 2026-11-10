# Roadmap

What Twig needs to be a complete git client, roughly in the order planned.
Tick an item when it lands on main.

## Remotes

- [x] Fetch, pull and push over HTTPS, with progress and cancellation.
- [x] Credentials: personal access tokens stored in the Keychain.
- [ ] SSH: keys generated or imported into the app and kept in the Keychain.
      libgit2 needs libssh2 and a crypto library for this; neither is built yet.
- [x] Clone, into a chosen folder on macOS and into Documents on iOS.
- [ ] Add, rename and remove remotes; track a remote branch on checkout.
- [ ] Hosting accounts (pull requests, repository lists).

## Working copy

- [x] Stage and unstage single hunks and lines.
- [x] Discard changes, with confirmation.
- [x] Amend the last commit.
- [ ] Commit templates.
- [x] Stash: save, apply, pop and drop.
- [x] Resolve merge conflicts.
- [x] Notice changes on disk and refresh without being asked.
- [ ] Image diffs; syntax colouring; side-by-side diffs.
- [ ] Ignore files; Git LFS.

## History

- [x] Search by message, author, hash and path.
- [x] File history and blame.
- [x] Browse the tree at a commit.
- [x] Compare two commits or branches.
- [x] Reflog.
- [x] Show diffs of a merge against each parent.

## Branching

- [x] Merge, rebase, cherry-pick and revert.
- [ ] Interactive rebase: reorder, squash, reword, drop.
- [x] Rename and delete branches; create and delete tags.
- [ ] Publish tags.
- [x] Reset to a commit.
- [x] Group branches by folder in the sidebar.
- [ ] Submodules: update, add, remove. Worktrees: add, remove, open.
- [ ] Undo for the operations above.

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
