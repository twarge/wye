# Twig

A git client for macOS and iOS, written in SwiftUI. Free, and open source
under the Apache License 2.0.

![History and commit detail on iPad](docs/images/ipad-history.png)

Twig is built for the App Store, so it runs in the sandbox and does not use
the `git` command line tool. Everything goes through
[libgit2](https://libgit2.org), compiled from source into the app.

## What works

- **Repositories:** open one from any folder, or clone one over HTTPS.
- **Sidebar:** branches grouped into folders, tags, remotes, stashes,
  submodules, worktrees and the reflog, with ahead/behind counts.
- **History:** a commit graph with reference badges, read a page at a time;
  search by message, author, hash or path; compare two commits or branches.
- **Commit detail:** the changes as diffs, or the files at that commit; file
  history and blame.
- **Working copy:** stage and unstage files, hunks or single lines; discard;
  commit and amend; stash; resolve conflicts. Changed files as a list or a
  folder tree; ignore, stop tracking, rename, trash or restore a file from
  its menu; commit templates and recent messages; diff options for context
  lines and whitespace.
- **Branching:** merge, rebase, cherry-pick, revert and reset; create, rename
  and delete branches and tags.
- **Remotes:** fetch, pull (merge, rebase or fast-forward only, stashing
  local changes around it) and push with progress, sync, push to any remote
  and name, publish and delete tags and remote branches, open remotes on
  their website; access tokens kept in the Keychain.
- **App:** notices changes other tools make and refreshes; a full menu bar
  and keyboard shortcuts, also on iPad; window tabs on macOS (⌘T); quick open (⇧⌘O) for branches, tags
  and repositories; repository groups, search and sorting.

See [docs/roadmap.md](docs/roadmap.md) for what comes next,
[docs/missing-features.md](docs/missing-features.md) for everything not built
yet, and [docs/app-store.md](docs/app-store.md) for how releases are made.

## Building

Requires Xcode 27 or later.

```bash
git clone --recurse-submodules <this repository>
```

```bash
make run
```

Or open `Twig.xcodeproj` and run the Twig scheme on a Mac, iPhone or iPad.
`make test` runs the engine's tests and `make ios` builds for the simulator.

## Layout

| Path | What it is |
| --- | --- |
| `App/` | The app target: an entry point, plists, entitlements and assets. |
| `Sources/GitKit/` | The git engine: a Swift API over libgit2. No interface code. |
| `Sources/TwigUI/` | The whole interface, shared by macOS and iOS. |
| `Tests/GitKitTests/` | Tests that check GitKit against the command line git. |
| `Vendor/libgit2/` | libgit2, as a git submodule. |
| `Vendor/Clibgit2/` | The build configuration and module map that let Swift Package Manager compile libgit2. |

Platform differences are kept to one file,
`Sources/TwigUI/Support/Platform.swift`.

## Licenses

Twig is licensed under the Apache License 2.0; see [LICENSE](LICENSE).

libgit2 is licensed under the GNU GPL version 2 with a linking exception that
permits linking it into programs under other licenses. It is included as a
submodule, not copied into this repository, and is used unmodified. See
`Vendor/libgit2/COPYING`.
