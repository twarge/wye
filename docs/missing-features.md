# Missing features

Everything a complete desktop git client offers that Wye does not do yet,
found by walking through the menus, right-click menus and screens of an
established one and comparing them with Wye. [plan.md](plan.md) says how
features should be built; [roadmap.md](roadmap.md) is the short checklist.

Each item is marked:

- **Missing** — nothing there yet.
- **Partial** — the engine or a narrower form exists; what is lacking is named.
- **Not planned** — cannot work in the App Store sandbox, or out of scope.

## Windows and navigation

| Feature | Status |
| --- | --- |
| Tabs: several repositories in one window, Show All Tabs, Move Tab to New Window | Done. Window tabs on macOS (⌘T), with the system's Show All Tabs and Move Tab to New Window. |
| Back / Forward through the views visited (⌘[ ⌘]) | Done. ⌘[ and ⌘], and toolbar buttons; up to 50 places per window. |
| Open Recent menu | Done. File ▸ Open Recent, with Clear Menu. |
| "Show HEAD Branch" (⌘0): jump to the checked-out branch's history | Done. View ▸ Show HEAD selects `HEAD`'s commit in the history. |
| Reveal in Finder / Files for the repository and for a file | Done on macOS: a changed file from its menu, the repository from the Working Copy row's menu, a worktree from its menu. iOS has no public way to open Files at a file. |
| Open in Terminal | Not planned (sandbox) |
| Quick actions: one palette that runs any command, not only navigation | Done. Quick open (⇧⌘O) jumps to repositories, branches and tags and runs commands. |
| Activity window: a log of every operation with its output and errors | Done. Window ▸ Activity on macOS, a sheet on iOS; kept for the session. Network operations keep what the server said (a hook's refusal, a link). The library's Activity button counts failures not yet looked at. |
| Errors that do not stop the window | Done. A failure shows as a notice in a strip at the top of the window, named after what failed, with a button for what would fix it (Pull, Fetch, Show Working Copy, Open Settings) and the server's own words behind Show Details. Sheets and settings show theirs in place. Alerts remain only where something must be typed or confirmed. After a push, a link the server sends becomes a Create Pull Request button. |
| Customizable toolbar | Missing |
| Copy file path, copy commit info (hash, author, date, subject) | Done. File paths (relative and full) from the working copy and commit detail; the repository's and a worktree's folder; a commit's hash or its info, for one commit or several; a branch's, remote branch's or tag's name. |

## Repository list

| Feature | Status |
| --- | --- |
| See what is uncommitted or unpushed in every repository at once | Done. Review, beside Repositories in the list's toolbar: each repository's changed files and unpushed commits, with Push. |
| Pull every repository | Done. Pull All, a few at a time, with a report that lists what failed or stopped on conflicts first. |
| Find repositories by scanning folders on disk | Done. A watched folder lists every repository in it and follows as they come and go. |
| Create a new empty repository | Done. New Repository… (⌃⌘N), with an optional README and .gitignore. |
| Publish a local repository to a hosting service | Done. Publish to a signed-in service from the Working Copy row's menu when there is no remote. |
| Hosting accounts: browse and clone your repositories on a service | Done. Clone from Account… in the clone sheet, for GitHub, GitLab, Bitbucket and Gitea/Forgejo. |
| Repository description | Missing |

## Working copy

| Feature | Status |
| --- | --- |
| View changed files as a folder tree | Done. A List / Tree switch; folders fold, and a folder's checkbox stages everything under it. |
| Sort by status or by name; filter the file list | Done. By path, name or status, and a filter field. |
| Show unchanged files, ignored files, assume-unchanged files | Partial. Ignored and assume-unchanged files on request; unchanged files not. |
| Compare working tree to `HEAD`, working tree to index, index to `HEAD` as whole-tree views | Done. From the Working Copy row's menu and the Working Copy menu: every changed file with its diff, untracked files left out as git leaves them out. |
| Snapshots: stash the changes and keep them in place | Done. Untracked files included, staged changes staged again; listed with the stashes, marked as snapshots. |
| Stash only some files or hunks | Done. Selected files, folders, hunks or lines. |
| Apply a patch file to the working copy; save changes as a patch | Done. Patches apply to the working copy; all, staged or selected changes save as a patch. |
| Ignore a file, a folder or an extension from its menu; edit the ignore list | Done. In `.gitignore` or `.git/info/exclude`, offering to stop tracking files the rule matches; an editor in the working copy's menu. |
| Stop tracking a file; mark assume-unchanged | Done |
| Move a file to the Trash, rename it, open it, Quick Look it | Done. Rename stages the move as `git mv` does. Open is macOS only; on iOS, Quick Look's share button opens files elsewhere. |
| Restore one file from another revision | Done. From a file's menu in commit detail, into the working tree. |
| Commit subject length marker and reflow of the description | Partial. The marker (limits set in Settings); no reflow. |
| Commit message templates and a history of past messages | Done. The repository's `commit.template` when it is inside the repository, templates kept in Settings, and the last 20 messages. |
| Autocomplete in the message: changed file names, people, issue references, fixup targets | Done. File names, people, issue references, Co-authored-by and fixup targets. |
| Fixup and squash commits aimed at an earlier commit, with autosquash | Done. From a commit's menu, with autosquash in the interactive rebase sheet. |
| Generate or rephrase a commit message with a language model | Not planned for now |
| Choose the author for one commit; several author profiles | Done. Identities in Settings; the composer picks one per commit and a repository can prefer one. |
| Sign commits; show whether a commit's signature verifies | Partial. SSH signing and verification with an allowed-signers list. GPG signatures show as signed but cannot be verified; tags are not signed. |
| Image diffs, side by side and overlaid | Done. Side by side, swipe and onion skin. |
| Syntax colouring; show whitespace; ignore whitespace changes | Done. Syntax colouring for about twenty languages with themes; invisible characters; three ways to ignore whitespace. Partial staging pauses while whitespace is ignored. |
| Context line count for diffs | Done. 1 to 10, 15, 25 or 50, in Settings. |
| Auto-collapse diffs once a commit changes many files | Done. Past 5, 10, 25 or 50 files, or never. |
| Open in an external diff or merge tool | Not planned (sandbox) |
| A built-in three-way merge view for conflicts | Done. Resolve… on a conflicted file. |
| Git LFS: track patterns, fetch, pull, push, show pointer files properly | Missing. Needs a transfer client written for the sandbox. |

## History

| Feature | Status |
| --- | --- |
| Hide the graph; first-parent only | Done |
| Sort by date instead of topologically | Done |
| Group by day or week, or not at all | Done |
| Compact and regular row sizes | Done on macOS; iOS switches by width. |
| Filter by author, date range, branch | Done. A Filter menu with tokens in the search field. |
| Select several commits and act on them together | Done. Cherry-pick, revert, copy hashes or info, compare first and last. |
| Drag a commit onto a branch to cherry-pick; drag branches to merge or rebase | Done. Every drop asks before acting. |
| Save a commit as a patch file; export a commit's files | Done. Save as Patch writes `git format-patch`'s format; Export Files writes the commit's files to a zip, as `git archive` does, executable bits and symbolic links kept and submodules as empty folders. `export-ignore` and `export-subst` are not applied, and archives past 4 GB or 65,535 files are refused (no Zip64). |
| Compare a commit with any other revision from its menu | Done |
| Reveal a reference or a search result in the full history | Done for search results, commits in one branch's history, reflog entries, `HEAD`, branches, remote branches and tags. Not from the Compare sheet's commits, which show in the history when clicked. |
| Edit a commit's message, author or date after the fact | Done. Any commit in the current history; warns when it is already on a remote. |
| Interactive rebase: reorder, squash, fixup, reword, drop, edit | Done. Pick, reword, squash, fixup and drop, reordered by drag or command. Merge commits in the range are flattened. |
| Undo the last operation (⌘Z) across commits, merges, deletes and discards | Done, with Redo, kept across launches. Not undoable: fetch, pull and push; finishing, skipping or aborting a stopped merge, rebase, cherry-pick or revert, and an operation that stops on a conflict (Abort undoes that); resolving conflicts; remote management; file moves, ignore rules and the other file actions not yet recorded. |
| Avatars for authors | Missing. Initials only; fetching portraits has privacy cost. |
| Issue references and links in messages made clickable | Done. URLs and issue references; tracker patterns per repository. |
| Notes | Done. Shown in the commit detail; add, edit and remove from the commit's menu. |

## Branches and tags

| Feature | Status |
| --- | --- |
| Review of branches: each compared with a base branch, with ahead/behind, last update, contributors and whether it merges cleanly | Missing |
| "Fully merged" and "stale" marks on branches in the sidebar | Done. Merged into `origin/HEAD`'s branch, else `main`, else `master`, else the current branch; stale after a time set in Settings (3 months unless changed). Each branch can hide its merged mark. |
| Archive branches (hide without deleting), automatically after a time | Done. An Archived Branches section; automatic archiving after a time set in Settings, off unless turned on, which a branch can opt out of. Kept by Wye per repository, not in git. |
| Pin branches to the top | Done. Kept by Wye per repository, not in git. |
| Check out a branch into a new worktree | Done. From the branch's menu; a branch checked out in another worktree is marked in the sidebar. |
| Push a branch to a chosen remote and name ("push to…") | Done |
| Publish a tag; push all tags; delete a remote tag | Done |
| Rename and delete a remote branch | Done. A rename pushes the new name and deletes the old one. |
| Pull one remote branch into the current branch from its menu | Done |
| Check out, reset, merge with or rebase on any revision, chosen by name or typed | Done. A revision picker from the Working Copy row's menu, the Repository menu and quick open. |
| Push any commit to a chosen remote branch | Done. Push Revision To…, confirmed as a force push with lease when it would drop commits there. |
| Make a branch from a stash (`git stash branch`) | Done. From the stash's menu, undoably. |
| Rebase onto (move a range of commits to a new base) | Done. |
| Merge preview: say beforehand whether it will conflict | Done. In the merge, rebase and pull sheets. |
| Sort and limit long lists of tags and remote branches | Done. By name, version or most recent. The sidebar lists the 5 most recent tags, a number set in Settings, with More tags… for the rest; a remote's long list shows its first 30 branches. |
| Parent branches and stacked branches (a branch that follows another, restacked when its parent changes) | Not planned for now. Its menu items (Track Parent Branch, New Stacked Branch) are left out. |
| Branching workflows: named conventions (feature / release / hotfix) with start and finish actions | Missing |
| Export the files of a branch or tag as an archive | Done. A zip, from the branch's, remote branch's or tag's menu. |
| Filter the sidebar by typing | Done. |

## Remotes and hosting

| Feature | Status |
| --- | --- |
| SSH remotes, with keys generated or imported into the app | Done. Ed25519 and ECDSA keys, made in the app or imported from an OpenSSH key file (passphrase-protected ones too); host keys checked against Wye's known hosts, with GitHub's, GitLab's and Bitbucket's built in. Not supported: RSA keys, ssh-agent, `~/.ssh/config`, jump hosts and proxies, agent forwarding, security keys (`sk-` keys), certificates, password or keyboard-interactive login, hashed known_hosts entries. Each stored key is offered in turn; there is no per-host choice of key yet. |
| Fetch with options: one remote, all, prune, tags | Done. libgit2 brings all of a remote's tags where git brings only those on fetched commits. |
| Pull with options: rebase instead of merge, fast-forward only, autostash | Done. `pull.rebase`, `branch.<name>.rebase` and `pull.ff = only` are read; `pull.ff = false` is not. |
| Sync: pull then push in one step | Done |
| Stash automatically around pull, checkout, merge and rebase | Done. Ask, always or never, in Settings. A stash kept while an operation is stopped on conflicts is popped by hand. |
| Prune obsolete remote branches from the remote's menu | Done. Prune asks the remote which branches it has, as `git remote prune` does, and fetches nothing; Fetch from the remote's menu prunes too. |
| Edit a remote's refspecs and its push URL | Done. In the repository's settings. |
| Open the remote, a branch or a commit on its website | Done. Remotes, remote branches and commits from their menus. |
| Relative-path and `file://` remote URLs resolved as git resolves them | Done |
| Pull requests: list, read, comment, create, check out, merge, close | Partial. List, read, comment, approve, create, check out, merge and close on GitHub, GitLab, Bitbucket and Gitea/Forgejo. Comments on diff lines are read-only. |
| Sign in to hosting services (OAuth device flow, tokens), several accounts | Partial. Several accounts per host with tokens. The OAuth device flow (GitHub, GitLab) needs client ids configured in the app. |
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
| Worktrees: add, open, move, lock, remove | Done. Also prune. On macOS a new worktree goes into a folder the user picks; on iOS into Documents. A worktree Wye was not given asks for its folder when opened. |

## Repository settings

| Feature | Status |
| --- | --- |
| A settings screen per repository: author, default remote, pull behaviour | Done. Repository ▸ Repository Settings…. |
| Edit the repository's git configuration | Done. The repository's own configuration; never the user's global file. |
| Remote settings: URLs, refspecs, default branches | Done. Name, URLs, refspecs and default branch. |
| Ignore patterns editor | Done. From the working copy's menu. |
| Repair an invalid or damaged repository; run maintenance (gc) | Missing |

## App settings

| Feature | Status |
| --- | --- |
| Author profiles, switched per repository | Done. Identities in Settings. |
| Appearance: theme, diff font and size, tab width | Done. Code font, size, tab width and syntax theme. |
| Global git configuration editor (default branch name, pull mode, pruning) | Partial. Pull mode and autostash are app settings, not git configuration. |
| Fetch in the background on a schedule | Done. While the app runs, and by background refresh on iOS. |
| Notifications when a background fetch finds new commits | Done. |
| iOS: Shortcuts actions, widgets, Files provider, share sheet "clone this URL" | Done. App Intents for Siri and Shortcuts (pull, push, fetch, status, commit, check out, stash, pull all, find unpushed work, clone); the Unpushed Changes widget and a Repository widget with Fetch and Pull buttons (also on the Mac desktop), Lock Screen widgets and a Fetch All control; a share extension that hands a URL to the clone sheet. A File Provider extension makes Wye a location in the Files app, with `.git` hidden. |
| Transfers that finish in the background, with progress on the Lock Screen | Done on iOS, through continued processing tasks: a clone, fetch, pull, push or Pull All carries on when the app leaves the screen, and can be stopped from its Live Activity. |
| Pull from the notification about new commits | Done. Pull and Open actions on it. |
| Draft a commit message from the changes | Done where Apple Intelligence is available, on the device. Messages ▸ Draft from Changes. |
| macOS: menu bar item, Finder badges and Open in Wye | Done. Both off until turned on: the menu bar item in Settings, the Finder extension in System Settings. |
| Settings the same on every device | Partial. Sync through iCloud is built and stays hidden until the app is signed for it (docs/app-store.md, "iCloud"). SSH keys can be kept in iCloud Keychain, off unless turned on. |
| Handoff of the open repository between devices | Not planned for now |

## Not planned, and why

- **Hooks.** A sandboxed app cannot run a repository's scripts.
- **Terminal, external editors and external diff tools.** Outside the sandbox.
- **The user's `~/.gitconfig`, `~/.ssh` and credential helpers.** Unreadable
  from the sandbox; Wye keeps its own.
- **Subversion.**
- **Licensing, trials, update checks.** Wye is free and updates through the
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
