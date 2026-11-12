#!/bin/sh
# Brings the string catalogs up to date with the strings in the sources.
# `make strings` runs it.
#
# The interface is in the WyeUI package, but its text is looked up in the
# running app's own bundle, so the app's catalog (App/Resources) holds the
# strings of the app target and of the packages it links. Xcode fills a
# catalog only from its own target's sources and would call the rest stale;
# this gathers the strings itself, and marks the entries as kept by hand so
# Xcode leaves them be. Each extension has a catalog of its own, filled the
# same way from its sources and WyeShared's.
#
# Where the strings come from, most exact first:
#
# 1. The compiler, for the packages: they are compiled here for macOS with
#    `-emit-localized-strings`, which knows each interpolation's type and
#    so writes the key the app will look up (`Pull %lld of %lld`).
# 2. The last Xcode build, for the app and extension targets and for the
#    App Shortcuts phrases, which only a build works out. Run
#    `make build ios` first for a complete catalog.
# 3. A reading of the sources without compiling them, which also sees the
#    strings only iOS compiles. It cannot tell an interpolation's type, so
#    it is asked to leave those strings out rather than guess.
set -eu

cd "$(dirname "$0")/.."
ROOT="$PWD"
INTERMEDIATES="${1:-.build/xcode/Build/Intermediates.noindex}/Wye.build"
COMPILED="$ROOT/.build/strings-data/macos"

mkdir -p "$COMPILED"
echo "Compiling the packages to read their strings…"
swift build --scratch-path .build/strings-macos --target WyeUI \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$COMPILED" \
    > /dev/null

# sync <catalog> <build target> <source folder>...: one catalog from the
# strings of these folders.
sync() {
    catalog="$1"
    target="$2"
    shift 2
    work="$(mktemp -d)"
    list="$work/list"
    : > "$list"
    for folder in "$@"; do
        # 1. What the compiler wrote for this folder's files. They share a
        # directory with every other module's, so they are picked by name.
        find "$folder" -name '*.swift' | while IFS= read -r source; do
            data="$COMPILED/$(basename "$source" .swift).stringsdata"
            if [ -f "$data" ]; then echo "$data" >> "$list"; fi
        done
        # 3. The sources as read. Its warnings are only about the
        # interpolated strings it was told to leave out.
        out="$work/$(echo "$folder" | tr '/' '-')"
        mkdir -p "$out"
        find "$folder" -name '*.swift' -print0 | xargs -0 xcrun xcstringstool extract \
            --SwiftUI --modern-localizable-strings --avoid-arg-placeholder --omit-empty-stringsdata \
            --output-directory "$out" > /dev/null 2>&1
        find "$out" -name '*.stringsdata' >> "$list"
    done
    # 2. The last Xcode build.
    if [ -d "$INTERMEDIATES" ]; then
        find "$INTERMEDIATES" -path "*/Debug*/$target.build/*" -name '*.stringsdata' >> "$list"
        for name in WyeUI-t WyeShared-t; do
            find "$INTERMEDIATES" -path "*/Debug*/$name.build/*" -name 'ExtractedAppShortcutsMetadata.stringsdata' >> "$list"
        done
    fi
    if [ ! -s "$list" ]; then
        echo "No strings found for $catalog; skipped." >&2
        rm -rf "$work"
        return
    fi
    if [ ! -f "$catalog" ]; then
        mkdir -p "$(dirname "$catalog")"
        printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' > "$catalog"
    fi
    # Entries become the compiler's again for the sync, so that ones no
    # longer in the sources are found; then back to kept by hand. An entry
    # gone from the sources goes, unless someone translated it: that one
    # stays, marked stale, for a person to decide.
    python3 - "$catalog" <<'PY'
import json, sys
path = sys.argv[1]
catalog = json.load(open(path))
for entry in catalog.get("strings", {}).values():
    if entry.get("extractionState") == "manual":
        del entry["extractionState"]
json.dump(catalog, open(path, "w"), ensure_ascii=False, indent=2, sort_keys=True)
PY
    args=""
    while IFS= read -r file; do
        args="$args --stringsdata $file"
    done < "$list"
    # shellcheck disable=SC2086
    xcrun xcstringstool sync "$catalog" $args
    python3 - "$catalog" <<'PY'
import json, sys
path = sys.argv[1]
catalog = json.load(open(path))
strings = catalog.get("strings", {})
for key in list(strings):
    entry = strings[key]
    if entry.get("extractionState") == "stale":
        if not entry.get("localizations"):
            del strings[key]
        continue
    entry["extractionState"] = "manual"
with open(path, "w") as file:
    json.dump(catalog, file, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    file.write("\n")
print(f"{path}: {len(strings)} strings")
PY
    rm -rf "$work"
}

sync App/Resources/Localizable.xcstrings Wye App/Sources Sources/WyeUI Sources/WyeShared Sources/GitKit
sync Extensions/Widgets/Localizable.xcstrings WyeWidgets Extensions/Widgets Sources/WyeShared
sync Extensions/Share/Localizable.xcstrings WyeShare Extensions/Share Sources/WyeShared
sync Extensions/Files/Localizable.xcstrings WyeFiles Extensions/Files Sources/WyeShared
sync Extensions/Finder/Localizable.xcstrings WyeFinder Extensions/Finder Sources/WyeShared
