#!/bin/sh
# Copies every third-party licence text into the built app bundle.
#
# Settings ▸ About ▸ Acknowledgements reads these files back out of the bundle
# (<Resources>/ThirdPartyLicenses/<component>/...) and shows them. libgit2 is
# compiled into the app under the GPL version 2 with its linking exception, and
# the parts of it Package.swift builds carry licences of their own: xdiff
# (LGPL 2.1), the SHA-1 collision detection code (MIT) and llhttp (MIT). The
# first three are all in libgit2's COPYING, which also holds the notices for the
# smaller pieces it borrows; llhttp's is its own file.
#
# Only what the binary actually contains is listed.
#
# Run as a build phase. Sources are the libgit2 submodule; a missing one is a
# warning rather than a build failure, because submodules are not always checked
# out and a developer build should not be blocked by that — but a Release build
# fails, since shipping without them is the thing this exists to prevent.
set -eu

SRCROOT_DIR="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# TARGET_BUILD_DIR, not BUILT_PRODUCTS_DIR: in an archive (DEPLOYMENT_LOCATION=YES)
# the app is assembled under DSTROOT and BUILT_PRODUCTS_DIR only holds a symlink
# to it, and the script sandbox matches resolved paths, so writing through the
# symlink is denied. The two are the same directory in an ordinary build. The
# build phase declares its outputs against TARGET_BUILD_DIR too, so the sandbox
# allow-list and this destination stay the same path.
RESOURCES="${TARGET_BUILD_DIR:-${BUILT_PRODUCTS_DIR:-.}}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-Resources}"
DEST="${RESOURCES}/ThirdPartyLicenses"
CONFIG="${CONFIGURATION:-Debug}"

missing=0

install_license() {
    component="$1"
    source_path="$2"
    if [ ! -f "$source_path" ]; then
        echo "warning: third-party licence missing for ${component}: ${source_path}"
        missing=$((missing + 1))
        return
    fi
    mkdir -p "${DEST}/${component}"
    cp -f "$source_path" "${DEST}/${component}/$(basename "$source_path")"
}

LIBGIT2="${SRCROOT_DIR}/Vendor/libgit2"
install_license libgit2 "${LIBGIT2}/COPYING"
install_license llhttp  "${LIBGIT2}/deps/llhttp/LICENSE-MIT"

# Twig's own licence, beside them, so the app carries the terms it is under.
cp -f "${SRCROOT_DIR}/LICENSE" "${RESOURCES}/LICENSE.txt"

if [ "$missing" -gt 0 ] && [ "$CONFIG" != "Debug" ]; then
    echo "error: ${missing} third-party licence text(s) missing from a ${CONFIG} build; run 'make deps' to fetch the libgit2 submodule"
    exit 1
fi
