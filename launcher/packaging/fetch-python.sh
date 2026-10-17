#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fetches the pinned python-build-standalone CPython (aarch64 macOS, install_only_stripped),
# verifies its SHA-256, unpacks it into $1 (the python root: bin/, lib/) and prunes what the
# launcher's pipeline (scripts/*.py, stdlib only) does not need. Result: ~27 MB (~37 MB with
# the optional precompiled stdlib), the interpreter links only /usr/lib and /System.
#   fetch-python.sh <target dir>          e.g. .../Hunter's Lantern.app/Contents/Resources/python
# Environment: PBS_CACHE (download cache, default ~/Library/Caches/bbport-launcher),
#              PBS_PYC=0 skips precompiling (stdlib ships without .pyc: +50 ms per interpreter start).
# To bump the version: take the tag, file name and hash from the release's SHA256SUMS
# (https://github.com/astral-sh/python-build-standalone/releases) and edit the three lines below.
set -euo pipefail

PBS_TAG=20261013
PBS_FILE="cpython-3.13.16+20261013-aarch64-apple-darwin-install_only_stripped.tar.gz"
PBS_SHA256=16a5332fb0dcb77f163fc8f8cbccd95be1644cc53e68e5d2a79f50afd6680a0e
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE//+/%2B}"

target=${1:?usage: fetch-python.sh <target dir>}
cache=${PBS_CACHE:-$HOME/Library/Caches/bbport-launcher}
archive=$cache/$PBS_FILE

mkdir -p "$cache"
verify() { [[ $(shasum -a 256 "$1" | cut -d' ' -f1) == "$PBS_SHA256" ]]; }
if [[ ! -f $archive ]] || ! verify "$archive"; then
    echo "Downloading $PBS_URL"
    curl -fsSL --retry 3 -o "$archive.part" "$PBS_URL"
    verify "$archive.part" || { echo "SHA-256 mismatch for $PBS_FILE" >&2; rm -f "$archive.part"; exit 1; }
    mv "$archive.part" "$archive"
fi

rm -rf "$target"
mkdir -p "$target"
tar -xzf "$archive" -C "$target" --strip-components=1

py=$target/lib/python3.13
# Tk/Tcl, headers, pkg-config, static libs, docs, the shared libpython (bin/python3.13 links the
# runtime statically), tools and packages that no pipeline step imports.
rm -rf "$target/include" "$target/share" "$target/lib/pkgconfig" \
       "$target/lib/tcl9" "$target/lib/tcl9.0" "$target/lib/tk9.0" "$target/lib/itcl4.3.8" \
       "$target/lib/thread3.0.6"
rm -f "$target"/lib/libtcl*.dylib "$target/lib/libpython3.13.dylib"
rm -rf "$py/idlelib" "$py/tkinter" "$py/ensurepip" "$py/turtledemo" "$py/pydoc_data" "$py/venv" \
       "$py/config-3.13-darwin" "$py/site-packages/pip" "$py"/site-packages/pip-*.dist-info \
       "$py/unittest" "$py/test" "$py/lib2to3"
rm -f "$py"/turtle.py "$py"/pydoc.py "$py"/doctest.py "$py"/this.py "$py"/antigravity.py \
      "$py"/lib-dynload/_tkinter*.so
rm -f "$target"/bin/idle3* "$target"/bin/pip* "$target"/bin/pydoc3* "$target"/bin/python3*-config
find "$target" -name '*.a' -delete

if [[ ${PBS_PYC:-1} != 0 ]]; then
    # unchecked-hash: stays valid whatever the file times become (copy, DMG, zip) and does not
    # need the sealed bundle to be writable; run the interpreter with -B.
    env -i PATH=/usr/bin:/bin "$target/bin/python3" -E -s -B -m compileall -q -j 0 \
        --invalidation-mode unchecked-hash "$py" >/dev/null
fi

"$target/bin/python3" -E -s -B -c 'import sys; print("python", sys.version.split()[0], "ready:", sys.prefix)'
du -sh "$target"
