#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Writes <build-dir>/appcast.xml for the DMG(s) in <build-dir>, signed with the Sparkle EdDSA key
# (docs/LAUNCHER_PLAN.md D13): appcast.sh <build-dir> <download-url-prefix> [<previous-dir>]
# <previous-dir> holds earlier releases' DMGs: Sparkle deltas from them to the new version are
# written to <build-dir> (*.delta, uploaded with the release); the appcast lists only the new
# version, so every URL in it is under <download-url-prefix>.
# The key (a base64 Ed25519 seed) comes from SPARKLE_ED_KEY or the file SPARKLE_ED_KEY_FILE; it is
# never written into the repository. Sparkle's tools come from its pinned release archive.
set -euo pipefail
[[ $# -eq 2 || $# -eq 3 ]] || { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
build=$(cd -- "$1" && pwd -P)
prefix=$2
previous=${3:-}
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
shopt -s nullglob
[[ -z $previous ]] || for dmg in "$previous"/HuntersLantern-*.dmg; do cp -- "$dmg" "$feed/"; done
args=(--download-url-prefix "$prefix" --maximum-versions 1 "$feed")
if [[ -n ${SPARKLE_ED_KEY:-} ]]; then
    printf '%s' "$SPARKLE_ED_KEY" | "$cache/bin/generate_appcast" --ed-key-file - "${args[@]}"
else
    [[ -f ${SPARKLE_ED_KEY_FILE:-} ]] || { echo "Set SPARKLE_ED_KEY or SPARKLE_ED_KEY_FILE." >&2; exit 1; }
    "$cache/bin/generate_appcast" --ed-key-file "$SPARKLE_ED_KEY_FILE" "${args[@]}"
fi
# Sparkle names deltas after the app ("Hunter's Lantern0.9.1-0.9.0.delta"); GitHub would rename
# such an asset on upload. They become HuntersLantern-0.9.1-0.9.0.delta, here and in the appcast
# (the signatures cover the files' contents, not their names).
rm -f -- "$build"/*.delta
deltas=0
for delta in "$feed"/*.delta; do
    name=$(basename -- "$delta")
    safe=HuntersLantern-${name#"Hunter's Lantern"}
    mv -- "$delta" "$build/$safe"
    python3 -I -c 'import sys, urllib.parse as u
p, old, new = sys.argv[1:]
s = open(p).read()
for form in (u.quote(old, safe="'"'"'"), u.quote(old)):
    s = s.replace("/" + form + chr(34), "/" + new + chr(34))
open(p, "w").write(s)' "$feed/appcast.xml" "$name" "$safe"
    grep -q "/$safe\"" "$feed/appcast.xml" || { echo "appcast.xml does not name $safe" >&2; exit 1; }
    deltas=$((deltas + 1))
done
mv -- "$feed/appcast.xml" "$build/appcast.xml"
rm -rf -- "$feed"
echo "Created $build/appcast.xml ($deltas delta(s))"
