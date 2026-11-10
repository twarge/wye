# Missing features

Everything a complete desktop git client offers that Twig does not do yet,
found by walking through the menus, right-click menus and screens of an
established one and comparing them with Twig. [plan.md](plan.md) says how
features should be built; [roadmap.md](roadmap.md) is the short checklist.

Each item is marked:

- **Missing** — nothing there yet.
- **Partial** — the engine or a narrower form exists; what is lacking is named.
- **Not planned** — cannot work in the App Store sandbox, or out of scope.

## Windows and navigation

| Feature | Status |
| --- | --- |
| Tabs: several repositories in one window, Show All Tabs, Move Tab to New Window | Missing. One repository per window. |
| Back / Forward through the views visited (⌘[ ⌘]) | Missing |
| Open Recent menu | Missing |
| "Show HEAD Branch" (⌘0): jump to the checked-out branch's history | Missing |
| Reveal in Finder / Files for the repository and for a file | Missing |
| Open in Terminal | Not planned (sandbox) |
| Quick actions: one palette that runs any command, not only navigation | Partial. Quick open jumps to branches, tags and repositories; it does not run commands. |
| Activity window: a log of every operation with its output and errors | Missing. Only the running operation shows. |
| Customizable toolbar | Missing |
| Copy file path, copy commit info (hash, author, date, subject) | Partial. Copy hash only. |

## Repository list

| Feature | Status |
| --- | --- |
| Find repositories by scanning folders on disk | Missing. Needs a folder the user grants. |
| Create a new empty repository | Missing in the interface; the engine can. |
| Publish a local repository to a hosting service | Missing |
| Hosting accounts: browse and clone your repositories on a service | Missing |
| Repository description | Missing |

## Working copy

| Feature | Status |
| --- | --- |
| View changed files as a folder tree | Missing. List only. |
| Sort by status or by name; filter the file list | Missing |
| Show unchanged files, ignored files, assume-unchanged files | Missing |
| Compare working tree to `HEAD`, working tree to index, index to `HEAD` as whole-tree views | Partial. Per file, staged and unstaged, only. |
| Snapshots: stash the changes and keep them in place | Missing |
| Stash only some files or hunks | Missing |
| Apply a patch file to the working copy; save changes as a patch | Missing |
| Ignore a file, a folder or an extension from its menu; edit the ignore list | Missing |
| Stop tracking a file; mark assume-unchanged | Missing |
| Move a file to the Trash, rename it, open it, Quick Look it | Missing |
| Restore one file from another revision | Missing |
| Commit subject length marker and reflow of the description | Missing |
| Commit message templates and a history of past messages | Missing |
| Autocomplete in the message: changed file names, people, issue references, fixup targets | Missing |
| Fixup and squash commits aimed at an earlier commit, with autosquash | Missing |
| Generate or rephrase a commit message with a language model | Not planned for now |
| Choose the author for one commit; several author profiles | Missing |
| Sign commits; show whether a commit's signature verifies | Missing |
| Image diffs, side by side and overlaid | Missing |
| Syntax colouring; show whitespace; ignore whitespace changes | Missing |
| Context line count for diffs | Missing. Fixed at three. |
| Auto-collapse diffs once a commit changes many files | Missing. Large files are cut short instead. |
| Open in an external diff or merge tool | Not planned (sandbox) |
| A built-in three-way merge view for conflicts | Missing. Ours / theirs / mark resolved only. |
| Git LFS: track patterns, fetch, pull, push, show pointer files properly | Missing. Needs a transfer client written for the sandbox. |

## History

| Feature | Status |
| --- | --- |
| Hide the graph; first-parent only | Missing |
| Sort by date instead of topologically | Missing |
| Group by day or week, or not at all | Missing. Months only. |
| Compact and regular row sizes | Missing on macOS; iOS switches by width. |
| Filter by author, date range, branch | Partial. Search covers message, author, hash and path. |
| Select several commits and act on them together | Missing |
| Drag a commit onto a branch to cherry-pick; drag branches to merge or rebase | Missing |
| Save a commit as a patch file; export a commit's files | Missing |
| Compare a commit with any other revision from its menu | Partial. The Compare sheet exists; there is no "compare with…" on a commit. |
| Reveal a reference or a search result in the full history | Partial |
| Edit a commit's message, author or date after the fact | Missing |
| Interactive rebase: reorder, squash, fixup, reword, drop, edit | Missing |
| Undo the last operation (⌘Z) across commits, merges, deletes and discards | Missing |
| Avatars for authors | Missing. Initials only; fetching portraits has privacy cost. |
| Issue references and links in messages made clickable | Missing |
| Notes | Missing |

## Branches and tags

| Feature | Status |
| --- | --- |
| Review of branches: each compared with a base branch, with ahead/behind, last update, contributors and whether it merges cleanly | Missing |
| "Fully merged" and "stale" marks on branches in the sidebar | Missing |
| Archive branches (hide without deleting), automatically after a time | Missing |
| Pin branches to the top | Missing |
| Check out a branch into a new worktree | Missing |
| Push a branch to a chosen remote and name ("push to…") | Missing. Pushes to the upstream only. |
| Publish a tag; push all tags; delete a remote tag | Missing |
| Rename and delete a remote branch | Missing |
| Pull one remote branch into the current branch from its menu | Missing |
| Rebase onto (move a range of commits to a new base) | Missing |
| Merge preview: say beforehand whether it will conflict | Missing |
| Sort and limit long lists of tags and remote branches | Missing |
| Parent branches and stacked branches (a branch that follows another, restacked when its parent changes) | Missing |
| Branching workflows: named conventions (feature / release / hotfix) with start and finish actions | Missing |
| Export the files of a branch or tag as an archive | Missing |
| Filter the sidebar by typing | Missing |

## Remotes and hosting

| Feature | Status |
| --- | --- |
| SSH remotes, with keys generated or imported into the app | Missing. libgit2 is built without SSH. |
| Fetch with options: one remote, all, prune, tags | Partial. Fetch and prune exist; no options sheet. |
| Pull with options: rebase instead of merge, fast-forward only, autostash | Partial. Merge only. |
| Sync: pull then push in one step | Missing |
| Stash automatically around pull, checkout, merge and rebase | Missing |
| Prune obsolete remote branches from the remote's menu | Partial. Happens on fetch. |
| Edit a remote's refspecs and its push URL | Missing |
| Open the remote, a branch or a commit on its website | Missing |
| Relative-path and `file://` remote URLs resolved as git resolves them | Partial. Relative paths fail. |
| Pull requests: list, read, comment, create, check out, merge, close | Missing |
| Sign in to hosting services (OAuth device flow, tokens), several accounts | Partial. One token per host. |
| Manage SSH public keys on a service | Missing |
| Proxy settings | Missing |
| Subversion remotes | Not planned |
| Code review services beyond pull requests | Not planned |

## Submodules and worktrees

| Feature | Status |
| --- | --- |
| Submodules: open as a repository, initialize, update, fetch, synchronize, check out a revision | Missing. Listed only. |
| Add a submodule; move, rename, delete one; change its URL | Missing |
| Update submodules automatically after checkout and pull | Missing |
| Show a submodule's change in a diff as the range of commits | Missing |
| Worktrees: add, open, move, lock, remove | Missing. Listed only. On iOS a worktree must live in Documents. |

## Repository settings

| Feature | Status |
| --- | --- |
| A settings screen per repository: author, default remote, pull behaviour | Missing |
| Edit the repository's git configuration | Missing |
| Remote settings: URLs, refspecs, default branches | Partial. Name and URL. |
| Ignore patterns editor | Missing |
| Repair an invalid or damaged repository; run maintenance (gc) | Missing |

## App settings

| Feature | Status |
| --- | --- |
| Author profiles, switched per repository | Missing. One identity. |
| Appearance: theme, diff font and size, tab width | Missing |
| Global git configuration editor (default branch name, pull mode, pruning) | Missing |
| Fetch in the background on a schedule | Missing |
| Notifications when a background fetch finds new commits | Missing |
| iOS: Shortcuts actions, widgets, Files provider, share sheet "clone this URL" | Missing |
| Handoff of the open repository between devices | Not planned for now |

## Not planned, and why

- **Hooks.** A sandboxed app cannot run a repository's scripts.
- **Terminal, external editors and external diff tools.** Outside the sandbox.
- **The user's `~/.gitconfig`, `~/.ssh` and credential helpers.** Unreadable
  from the sandbox; Twig keeps its own.
- **Subversion.**
- **Licensing, trials, update checks.** Twig is free and updates through the
  App Store.

## Suggested order

1. **Daily use, no new dependencies:** undo, autostash, pull by rebase, sync,
   push to…, tag publishing, tree view of the working copy, ignore from the
   menu, reveal in Finder, context line count, whitespace options, file-level
   actions, multi-selection in history, relative remote URLs.
2. **Rewriting history:** interactive rebase, fixup/squash with autosquash,
   editing a commit's message, rebase onto.
3. **Reviewing:** branches review, merged and stale marks, merge preview,
   three-way conflict view, image diffs, syntax colouring.
4. **Structure:** submodule and worktree actions, repository settings, author
   profiles, tabs, back/forward, the activity log.
5. **New dependencies:** SSH (libssh2 and a crypto library built from source),
   commit signing, Git LFS.
6. **Hosting:** accounts, pull requests, opening things on the web.
7. **Platform extras:** background fetch, notifications, Shortcuts, widgets.
