#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Writes <build-dir>/appcast.xml for the DMG(s) in <build-dir>, signed with the Sparkle EdDSA key
# (docs/LAUNCHER_PLAN.md D13): appcast.sh <build-dir> <download-url-prefix>
# The key (a base64 Ed25519 seed) comes from SPARKLE_ED_KEY or the file SPARKLE_ED_KEY_FILE; it is
# never written into the repository. Sparkle's tools come from its pinned release archive.
set -euo pipefail
[[ $# -eq 2 ]] || { sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
build=$(cd -- "$1" && pwd -P)
prefix=$2
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
cache=${SPARKLE_CACHE:-$HOME/Library/Caches/hunters-lantern/sparkle-$SPARKLE_VERSION}
if [[ ! -x $cache/bin/generate_appcast ]]; then
    mkdir -p -- "$cache"
    archive=$cache/Sparkle-$SPARKLE_VERSION.tar.xz
    curl -fsSL -o "$archive" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_SHA256  $archive" | shasum -a 256 -c - >/dev/null
    tar -xJf "$archive" -C "$cache"
fi
feed=$build/appcast-input
rm -rf -- "$feed"
mkdir -p -- "$feed"
cp -- "$build"/HuntersLantern-*.dmg "$feed/"
if [[ -n ${SPARKLE_ED_KEY:-} ]]; then
    printf '%s' "$SPARKLE_ED_KEY" | "$cache/bin/generate_appcast" --ed-key-file - --download-url-prefix "$prefix" "$feed"
else
    [[ -f ${SPARKLE_ED_KEY_FILE:-} ]] || { echo "Set SPARKLE_ED_KEY or SPARKLE_ED_KEY_FILE." >&2; exit 1; }
    "$cache/bin/generate_appcast" --ed-key-file "$SPARKLE_ED_KEY_FILE" --download-url-prefix "$prefix" "$feed"
fi
mv -- "$feed/appcast.xml" "$build/appcast.xml"
rm -rf -- "$feed"
echo "Created $build/appcast.xml"
