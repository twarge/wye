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
| "Show HEAD Branch" (⌘0): jump to the checked-out branch's history | Done. View ▸ Show HEAD selects `HEAD`'s commit in the history. |
| Reveal in Finder / Files for the repository and for a file | Done on macOS: a changed file from its menu, the repository from the Working Copy row's menu, a worktree from its menu. iOS has no public way to open Files at a file. |
| Open in Terminal | Not planned (sandbox) |
| Quick actions: one palette that runs any command, not only navigation | Partial. Quick open jumps to branches, tags and repositories; it does not run commands. |
| Activity window: a log of every operation with its output and errors | Missing. Only the running operation shows. |
| Customizable toolbar | Missing |
| Copy file path, copy commit info (hash, author, date, subject) | Done. File paths (relative and full) from the working copy and commit detail; the repository's and a worktree's folder; a commit's hash or its info, for one commit or several; a branch's, remote branch's or tag's name. |

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
| View changed files as a folder tree | Done. A List / Tree switch; folders fold, and a folder's checkbox stages everything under it. |
| Sort by status or by name; filter the file list | Done. By path, name or status, and a filter field. |
| Show unchanged files, ignored files, assume-unchanged files | Partial. Ignored and assume-unchanged files on request; unchanged files not. |
| Compare working tree to `HEAD`, working tree to index, index to `HEAD` as whole-tree views | Done. From the Working Copy row's menu and the Working Copy menu: every changed file with its diff, untracked files left out as git leaves them out. |
| Snapshots: stash the changes and keep them in place | Done. Untracked files included, staged changes staged again; listed with the stashes, marked as snapshots. |
| Stash only some files or hunks | Missing |
| Apply a patch file to the working copy; save changes as a patch | Partial. A patch file applies to the working copy, or to it and the index, from the history's and the Working Copy row's menus, undoably; a stash saves as a patch. Saving uncommitted changes as a patch is missing. |
| Ignore a file, a folder or an extension from its menu; edit the ignore list | Done. In `.gitignore` or `.git/info/exclude`, offering to stop tracking files the rule matches; an editor in the working copy's menu. |
| Stop tracking a file; mark assume-unchanged | Done |
| Move a file to the Trash, rename it, open it, Quick Look it | Done. Rename stages the move as `git mv` does. Open is macOS only; on iOS, Quick Look's share button opens files elsewhere. |
| Restore one file from another revision | Done. From a file's menu in commit detail, into the working tree. |
| Commit subject length marker and reflow of the description | Partial. The marker (limits set in Settings); no reflow. |
| Commit message templates and a history of past messages | Done. The repository's `commit.template` when it is inside the repository, templates kept in Settings, and the last 20 messages. |
| Autocomplete in the message: changed file names, people, issue references, fixup targets | Missing |
| Fixup and squash commits aimed at an earlier commit, with autosquash | Missing |
| Generate or rephrase a commit message with a language model | Not planned for now |
| Choose the author for one commit; several author profiles | Missing |
| Sign commits; show whether a commit's signature verifies | Missing |
| Image diffs, side by side and overlaid | Missing |
| Syntax colouring; show whitespace; ignore whitespace changes | Partial. Invisible characters and three ways to ignore whitespace; no syntax colouring. Hunks and lines are staged only from exact diffs, so partial staging pauses while whitespace is ignored. |
| Context line count for diffs | Done. 1 to 10, 15, 25 or 50, in Settings. |
| Auto-collapse diffs once a commit changes many files | Done. Past 5, 10, 25 or 50 files, or never. |
| Open in an external diff or merge tool | Not planned (sandbox) |
| A built-in three-way merge view for conflicts | Missing. Ours / theirs / mark resolved only. |
| Git LFS: track patterns, fetch, pull, push, show pointer files properly | Missing. Needs a transfer client written for the sandbox. |

## History

| Feature | Status |
| --- | --- |
| Hide the graph; first-parent only | Done |
| Sort by date instead of topologically | Done |
| Group by day or week, or not at all | Done |
| Compact and regular row sizes | Done on macOS; iOS switches by width. |
| Filter by author, date range, branch | Partial. Search covers message, author, hash and path. |
| Select several commits and act on them together | Done. Cherry-pick, revert, copy hashes or info, compare first and last. |
| Drag a commit onto a branch to cherry-pick; drag branches to merge or rebase | Missing |
| Save a commit as a patch file; export a commit's files | Done. Save as Patch writes `git format-patch`'s format; Export Files writes the commit's files to a zip, as `git archive` does, executable bits and symbolic links kept and submodules as empty folders. `export-ignore` and `export-subst` are not applied, and archives past 4 GB or 65,535 files are refused (no Zip64). |
| Compare a commit with any other revision from its menu | Done |
| Reveal a reference or a search result in the full history | Done for search results, commits in one branch's history, reflog entries, `HEAD`, branches, remote branches and tags. Not from the Compare sheet's commits, which show in the history when clicked. |
| Edit a commit's message, author or date after the fact | Partial. The last commit's message, undoably. Older commits, authors and dates are missing. |
| Interactive rebase: reorder, squash, fixup, reword, drop, edit | Missing |
| Undo the last operation (⌘Z) across commits, merges, deletes and discards | Done, with Redo, kept across launches. Not undoable: fetch, pull and push; finishing, skipping or aborting a stopped merge, rebase, cherry-pick or revert, and an operation that stops on a conflict (Abort undoes that); resolving conflicts; remote management; file moves, ignore rules and the other file actions not yet recorded. |
| Avatars for authors | Missing. Initials only; fetching portraits has privacy cost. |
| Issue references and links in messages made clickable | Missing |
| Notes | Missing |

## Branches and tags

| Feature | Status |
| --- | --- |
| Review of branches: each compared with a base branch, with ahead/behind, last update, contributors and whether it merges cleanly | Missing |
| "Fully merged" and "stale" marks on branches in the sidebar | Done. Merged into `origin/HEAD`'s branch, else `main`, else `master`, else the current branch; stale after a time set in Settings (3 months unless changed). Each branch can hide its merged mark. |
| Archive branches (hide without deleting), automatically after a time | Done. An Archived Branches section; automatic archiving after a time set in Settings, off unless turned on, which a branch can opt out of. Kept by Twig per repository, not in git. |
| Pin branches to the top | Done. Kept by Twig per repository, not in git. |
| Check out a branch into a new worktree | Done. From the branch's menu; a branch checked out in another worktree is marked in the sidebar. |
| Push a branch to a chosen remote and name ("push to…") | Done |
| Publish a tag; push all tags; delete a remote tag | Done |
| Rename and delete a remote branch | Done. A rename pushes the new name and deletes the old one. |
| Pull one remote branch into the current branch from its menu | Done |
| Check out, reset, merge with or rebase on any revision, chosen by name or typed | Done. A revision picker from the Working Copy row's menu, the Repository menu and quick open. |
| Push any commit to a chosen remote branch | Done. Push Revision To…, confirmed as a force push with lease when it would drop commits there. |
| Make a branch from a stash (`git stash branch`) | Done. From the stash's menu, undoably. |
| Rebase onto (move a range of commits to a new base) | Missing |
| Merge preview: say beforehand whether it will conflict | Missing |
| Sort and limit long lists of tags and remote branches | Missing |
| Parent branches and stacked branches (a branch that follows another, restacked when its parent changes) | Not planned for now. Its menu items (Track Parent Branch, New Stacked Branch) are left out. |
| Branching workflows: named conventions (feature / release / hotfix) with start and finish actions | Missing |
| Export the files of a branch or tag as an archive | Done. A zip, from the branch's, remote branch's or tag's menu. |
| Filter the sidebar by typing | Missing |

## Remotes and hosting

| Feature | Status |
| --- | --- |
| SSH remotes, with keys generated or imported into the app | Done. Ed25519 and ECDSA keys, made in the app or imported from an OpenSSH key file (passphrase-protected ones too); host keys checked against Twig's known hosts, with GitHub's, GitLab's and Bitbucket's built in. Not supported: RSA keys, ssh-agent, `~/.ssh/config`, jump hosts and proxies, agent forwarding, security keys (`sk-` keys), certificates, password or keyboard-interactive login, hashed known_hosts entries. Each stored key is offered in turn; there is no per-host choice of key yet. |
| Fetch with options: one remote, all, prune, tags | Done. libgit2 brings all of a remote's tags where git brings only those on fetched commits. |
| Pull with options: rebase instead of merge, fast-forward only, autostash | Done. `pull.rebase`, `branch.<name>.rebase` and `pull.ff = only` are read; `pull.ff = false` is not. |
| Sync: pull then push in one step | Done |
| Stash automatically around pull, checkout, merge and rebase | Done. Ask, always or never, in Settings. A stash kept while an operation is stopped on conflicts is popped by hand. |
| Prune obsolete remote branches from the remote's menu | Done. Prune asks the remote which branches it has, as `git remote prune` does, and fetches nothing; Fetch from the remote's menu prunes too. |
| Edit a remote's refspecs and its push URL | Partial. Push URL only. |
| Open the remote, a branch or a commit on its website | Done. Remotes, remote branches and commits from their menus. |
| Relative-path and `file://` remote URLs resolved as git resolves them | Done |
| Pull requests: list, read, comment, create, check out, merge, close | Partial. New Pull Request opens the hosting service's page for one (GitHub, GitLab, Bitbucket, Gitea and Forgejo) from a published branch's menu. Nothing is listed or read in Twig. |
| Sign in to hosting services (OAuth device flow, tokens), several accounts | Partial. One token per host. |
| Manage SSH public keys on a service | Missing |
| Proxy settings | Missing |
| Subversion remotes | Not planned |
| Code review services beyond pull requests | Not planned |

## Submodules and worktrees

| Feature | Status |
| --- | --- |
| Submodules: open as a repository, initialize, update, fetch, synchronize, check out a revision | Done. Update clones and recurses into nested submodules; relative URLs resolve against the superproject's remote as git does. Opens in a new tab on macOS, in the same window on iOS. |
| Add a submodule; move, rename, delete one; change its URL | Done. Add clones with progress and can be cancelled; removing deletes its folder and its repository in `.git/modules`, after confirming. |
| Update submodules automatically after checkout and pull | Done. A setting (never, ask, always) covers checkout, pull, merge, rebase and reset. |
| Show a submodule's change in a diff as the range of commits | Done. Up to 50 commits each way, when the submodule is cloned; status says new commits, modified or untracked content. |
| Worktrees: add, open, move, lock, remove | Done. Also prune. On macOS a new worktree goes into a folder the user picks; on iOS into Documents. A worktree Twig was not given asks for its folder when opened. |

## Repository settings

| Feature | Status |
| --- | --- |
| A settings screen per repository: author, default remote, pull behaviour | Missing |
| Edit the repository's git configuration | Missing |
| Remote settings: URLs, refspecs, default branches | Partial. Name, URL and push URL. |
| Ignore patterns editor | Done. From the working copy's menu. |
| Repair an invalid or damaged repository; run maintenance (gc) | Missing |

## App settings

| Feature | Status |
| --- | --- |
| Author profiles, switched per repository | Missing. One identity. |
| Appearance: theme, diff font and size, tab width | Partial. Tab width only. |
| Global git configuration editor (default branch name, pull mode, pruning) | Partial. Pull mode and autostash are app settings, not git configuration. |
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
5. **New dependencies:** commit signing, Git LFS.
6. **Hosting:** accounts, pull requests, opening things on the web.
7. **Platform extras:** background fetch, notifications, Shortcuts, widgets.
