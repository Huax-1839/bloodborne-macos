#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds the self-contained app (launcher/build.sh --bundle) and packs it into a DMG with a link
# to /Applications and the first-start note (docs/LAUNCHER_PLAN.md L6.1):
#   launcher/package.sh            -> launcher/build/HuntersLantern-<version>.dmg
# LANTERN_VERSION as in build.sh. LANTERN_SKIP_BUILD=1 packs the app already in launcher/build.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
build=$here/build
[[ -n ${LANTERN_SKIP_BUILD:-} ]] || bash "$here/build.sh" --bundle
app=$build/"Hunter's Lantern.app"
[[ -d $app ]] || { echo "No $app (run launcher/build.sh --bundle)." >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")

stage=$build/dmg
rm -rf -- "$stage"
mkdir -p -- "$stage"
ditto "$app" "$stage/Hunter's Lantern.app"
ln -s /Applications "$stage/Applications"
cp -- "$here/packaging/FIRST-START.txt" "$stage/First start – Erster Start.txt"

dmg=$build/HuntersLantern-$version.dmg
rm -f -- "$dmg"
hdiutil create -quiet -volname "Hunter's Lantern $version" -srcfolder "$stage" -fs APFS -format UDZO "$dmg"
rm -rf -- "$stage"
echo "Created $dmg ($(du -h "$dmg" | cut -f1))"
