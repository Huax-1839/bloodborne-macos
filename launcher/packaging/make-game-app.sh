#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Packages the runtime (bb-probe, libbbgpu, SDL3, MoltenVK) as the nested game app
# "Hunter's Lantern Game.app" (docs/LAUNCHER_PLAN.md D3), ad-hoc signed.
#   launcher/packaging/make-game-app.sh <dest-dir> [out-dir]
# <dest-dir>  where "Hunter's Lantern Game.app" is created (replaced if it exists)
# [out-dir]   the build output holding bb-probe, gpu/libbbgpu.dylib, lib/ (default: macos/out of
#             the repository this script lives in; build it with bash macos/build.sh)
# LANTERN_VERSION (default 0.0.0) becomes CFBundleShortVersionString and CFBundleVersion.
# LANTERN_ICON (optional) is an .icns copied to Contents/Resources/AppIcon.icns (CFBundleIconFile).
set -euo pipefail

[[ $# -ge 1 && $# -le 2 ]] || { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
repo=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
dest=$1
out=${2:-$repo/macos/out}
version=${LANTERN_VERSION:-0.0.0}
icon=${LANTERN_ICON:-}
[[ -z $icon || -f $icon ]] || { echo "LANTERN_ICON $icon does not exist." >&2; exit 1; }

for f in bb-probe gpu/libbbgpu.dylib lib/libSDL3.0.dylib lib/libMoltenVK.dylib; do
    [[ -f $out/$f ]] || { echo "Missing $out/$f (run bash macos/build.sh)." >&2; exit 1; }
done
mkdir -p -- "$dest"
app=$(cd -- "$dest" && pwd -P)/"Hunter's Lantern Game.app"
rm -rf -- "$app"
mkdir -p -- "$app/Contents/MacOS" "$app/Contents/Frameworks"

cp -- "$out/bb-probe" "$app/Contents/MacOS/bb-probe"
for lib in gpu/libbbgpu.dylib lib/libSDL3.0.dylib lib/libMoltenVK.dylib; do
    cp -- "$out/$lib" "$app/Contents/Frameworks/$(basename -- "$lib")"
done
exe=$app/Contents/MacOS/bb-probe
libs=("$app/Contents/Frameworks"/*.dylib)

# Every library the executable or the bundled libraries load must be the system's or inside the
# bundle: a path anywhere else (a Homebrew or build-tree copy) would not exist on a user's Mac.
for macho in "$exe" "${libs[@]}"; do
    while read -r dep; do
        case $dep in
            /usr/lib/* | /System/Library/*) ;;
            @rpath/libbbgpu.dylib | @rpath/libSDL3.0.dylib | @rpath/libMoltenVK.dylib) ;;
            *) echo "Unexpected dependency of $(basename -- "$macho"): $dep" >&2; exit 1 ;;
        esac
    done < <(otool -L "$macho" | tail -n +2 | awk '{print $1}')
done

# rpaths: the executable finds the libraries in ../Frameworks; the libraries (which also resolve
# @rpath names through the executable's rpaths) get their own entry for tools that load them alone.
set_rpaths() { # <file> <new rpath>
    local file=$1 new=$2 old
    codesign --remove-signature "$file" 2>/dev/null || true # install_name_tool warns about it
    while read -r old; do install_name_tool -delete_rpath "$old" "$file"; done \
        < <(otool -l "$file" | awk '$1 == "cmd" { rp = ($2 == "LC_RPATH") } rp && $1 == "path" { print $2 }')
    install_name_tool -add_rpath "$new" "$file"
}
set_rpaths "$exe" @executable_path/../Frameworks
for lib in "${libs[@]}"; do
    # MoltenVK and SDL3 have none to start with; deleting nothing is fine.
    set_rpaths "$lib" @loader_path
done

# Info.plist.
icon_plist=
if [[ -n $icon ]]; then
    mkdir -p "$app/Contents/Resources"
    cp -- "$icon" "$app/Contents/Resources/AppIcon.icns"
    icon_plist=$'\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>'
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>bb-probe</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.huax-1839.hunters-lantern.game</string>
	<key>CFBundleName</key>
	<string>Hunter's Lantern Game</string>
	<key>CFBundleDisplayName</key>
	<string>Hunter's Lantern Game</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
$icon_plist
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSArchitecturePriority</key>
	<array>
		<string>x86_64</string>
	</array>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.games</string>
	<key>GCSupportsGameMode</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Ad-hoc signature, inside out, without the hardened runtime (the runtime needs RWX pages).
for lib in "${libs[@]}"; do codesign --force -s - --timestamp=none "$lib"; done
codesign --force -s - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
echo "Created $app"
