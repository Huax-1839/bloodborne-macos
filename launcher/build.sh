#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Assembles "Hunter's Lantern.app" (docs/LAUNCHER_PLAN.md D2, D3, D14) from the Swift package in
# launcher/ into launcher/build/:
#   launcher/build.sh [--dev | --bundle] [--debug]
# --dev      (default) the app finds the runtime in this checkout: Info.plist gets
#            LanternRepository = the repository root, and macos/out, scripts/ and a Homebrew or
#            CLT python3 are used. Local only, never distribute it.
# --bundle   the self-contained app (L-M2): the game runtime as Contents/Helpers/"Hunter's Lantern
#            Game.app" (packaging/make-game-app.sh; macos/out is built first if bb-probe is
#            missing), the pinned embedded Python in Contents/Resources/python
#            (packaging/fetch-python.sh), the pipeline in Contents/Resources/pipeline.
#            Both modes put the license texts into Contents/Resources/Licenses
#            (packaging/collect-licenses.sh; the build fails when one is missing).
# --debug    a debug build of the launcher (default release).
# Everything is signed ad hoc, inside out, without the hardened runtime (D14).
# Environment: LANTERN_VERSION   CFBundleShortVersionString/CFBundleVersion (numeric, dotted).
#                                Default: the numeric part of the latest git tag (v1.2.3 -> 1.2.3),
#                                else 0.0.0.
#              LANTERN_SCRATCH   swift build --scratch-path (default launcher/.build).
# Updates (D13): --bundle writes Sparkle's feed (the latest GitHub release's appcast.xml) and the
# public EdDSA key into Info.plist (LANTERN_FEED_URL overrides the feed for tests); the private
# key is a CI secret (packaging/appcast.sh).
set -euo pipefail
SPARKLE_FEED=${LANTERN_FEED_URL:-https://github.com/Huax-1839/bloodborne-macos/releases/latest/download/appcast.xml}
SPARKLE_PUBLIC_KEY=3vXmh5UR6G/JKVDAUSQnwiYZH0sRTQWgKsKuef2Xa7U=

here=$(cd -- "$(dirname -- "$0")" && pwd -P)
repo=$(cd -- "$here/.." && pwd -P)
mode=dev
config=release
for arg in "$@"; do
    case $arg in
        --dev) mode=dev ;;
        --bundle) mode=bundle ;;
        --debug) config=debug ;;
        *) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    esac
done

version=${LANTERN_VERSION:-}
if [[ -z $version ]]; then
    tag=$(git -C "$repo" describe --tags --abbrev=0 2>/dev/null || true)
    tag=${tag#v}
    [[ $tag =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] && version=$tag || version=0.0.0
fi
[[ $version =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "LANTERN_VERSION '$version' is not numeric and dotted." >&2; exit 1; }
export LANTERN_VERSION=$version

build=$here/build
app=$build/"Hunter's Lantern.app"
mkdir -p -- "$build"

# 1. The launcher.
swift_args=(-c "$config" --arch arm64 --product HuntersLantern --package-path "$here")
[[ -z ${LANTERN_SCRATCH:-} ]] || swift_args+=(--scratch-path "$LANTERN_SCRATCH")
swift build "${swift_args[@]}"
bin=$(swift build "${swift_args[@]}" --show-bin-path)
[[ -x $bin/HuntersLantern ]] || { echo "No $bin/HuntersLantern after the build." >&2; exit 1; }

# 2. The icon (our own, drawn by packaging/make-icon.swift).
rm -rf -- "$build/AppIcon.iconset" "$build/AppIcon.icns"
swiftc -O "$here/packaging/make-icon.swift" -o "$build/make-icon"
"$build/make-icon" "$build/AppIcon.iconset"
iconutil -c icns "$build/AppIcon.iconset" -o "$build/AppIcon.icns"

# 3. The app skeleton.
rm -rf -- "$app"
mkdir -p -- "$app/Contents/MacOS" "$app/Contents/Resources"
cp -- "$bin/HuntersLantern" "$app/Contents/MacOS/HuntersLantern"
cp -- "$build/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

# Sparkle.framework (SwiftPM leaves it next to the executable). The app is not sandboxed, so its
# XPC services are not needed; Autoupdate and Updater.app stay.
frameworks=$app/Contents/Frameworks
mkdir -p -- "$frameworks"
ditto "$bin/Sparkle.framework" "$frameworks/Sparkle.framework"
rm -rf -- "$frameworks/Sparkle.framework/Versions/B/XPCServices" "$frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/HuntersLantern"

# SwiftPM's generated Bundle.module looks in Bundle.main.resourceURL first (its candidate list:
# resourceURL, the framework's resourceURL, bundleURL), so the resource bundles go to
# Contents/Resources. Next to the .app (bundleURL) would break the code signature.
for b in "$bin"/HuntersLantern_*.bundle; do
    cp -R -- "$b" "$app/Contents/Resources/"
done
# SwiftUI Text literals use Bundle.main, not Bundle.module: the main target's compiled .lproj
# folders (from its String Catalog) are also copied next to the bundles' own.
shopt -s nullglob
for lproj in "$bin"/HuntersLantern_HuntersLantern.bundle/Contents/Resources/*.lproj; do
    cp -R -- "$lproj" "$app/Contents/Resources/"
done
shopt -u nullglob

# Older toolchains (Xcode 26's swift build) copy String Catalogs instead of compiling them: compile
# what SwiftPM left uncompiled, so a release built anywhere has its German strings.
compile_catalogs() { # <target> <resources dir...>
    local target=$1 catalog table dir; shift
    for catalog in "$here/Sources/$target/Resources"/*.xcstrings; do
        table=$(basename -- "$catalog" .xcstrings)
        for dir in "$@"; do
            [[ -f $dir/de.lproj/$table.strings ]] || xcrun xcstringstool compile "$catalog" --output-directory "$dir"
            rm -f -- "$dir/$table.xcstrings"
        done
    done
}
compile_catalogs HuntersLantern "$app/Contents/Resources" \
    "$app/Contents/Resources/HuntersLantern_HuntersLantern.bundle/Contents/Resources"
compile_catalogs LanternCore "$app/Contents/Resources/HuntersLantern_LanternCore.bundle/Contents/Resources"
[[ -f $app/Contents/Resources/de.lproj/Localizable.strings ]] || { echo "No German strings in the app." >&2; exit 1; }

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>HuntersLantern</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.huax-1839.hunters-lantern</string>
	<key>CFBundleName</key>
	<string>Hunter's Lantern</string>
	<key>CFBundleDisplayName</key>
	<string>Hunter's Lantern</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>de</string>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSArchitecturePriority</key>
	<array>
		<string>arm64</string>
	</array>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.games</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>GPL-2.0-or-later</string>
</dict>
</plist>
PLIST
if [[ $mode == dev ]]; then
    plutil -insert LanternRepository -string "$repo" "$app/Contents/Info.plist"
else
    plutil -insert SUFeedURL -string "$SPARKLE_FEED" "$app/Contents/Info.plist"
    plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$app/Contents/Info.plist"
    plutil -insert SUEnableAutomaticChecks -bool true "$app/Contents/Info.plist"
fi
plutil -lint "$app/Contents/Info.plist" >/dev/null

# 4. --bundle: the runtime, Python and the pipeline.
if [[ $mode == bundle ]]; then
    [[ -f $repo/macos/out/bb-probe ]] || bash "$repo/macos/build.sh"
    LANTERN_ICON=$build/AppIcon.icns \
        bash "$here/packaging/make-game-app.sh" "$app/Contents/Helpers" "$repo/macos/out"

    python=$app/Contents/Resources/python
    bash "$here/packaging/fetch-python.sh" "$python"

    # The scripts import each other, so they stay in one folder; patches.py finds the XML in
    # ../patches next to it (Runtime.swift: pipeline/scripts, pipeline/patches).
    pipeline=$app/Contents/Resources/pipeline
    mkdir -p -- "$pipeline/scripts" "$pipeline/patches"
    cp -- "$repo"/scripts/*.py "$pipeline/scripts/"
    cp -- "$repo/patches/Bloodborne.xml" "$pipeline/patches/"
    find "$pipeline" -name __pycache__ -prune -exec rm -rf {} +

    # Python's Mach-O files (the interpreter, extension modules, dylibs) are signed first; the
    # nested game app is already signed by make-game-app.sh and stays as it is.
    while IFS= read -r -d '' f; do
        if [[ $(head -c 4 "$f" | xxd -p) =~ ^(cffaedfe|cafebabe|feedfacf)$ ]]; then
            codesign --force -s - --timestamp=none "$f"
        fi
    done < <(find "$python" -type f \( -name '*.so' -o -name '*.dylib' -o -path "$python/bin/*" \) -print0)
fi

# Licenses (GPL, Sparkle's MIT, and in --bundle the runtime's libraries and Python): in the app,
# for the About page, and on the DMG.
sparkle_license=${LANTERN_SCRATCH:-$here/.build}/artifacts/sparkle/Sparkle/LICENSE
if [[ $mode == bundle ]]; then
    bash "$here/packaging/collect-licenses.sh" "$app/Contents/Resources/Licenses" "$sparkle_license" \
        "$app/Contents/Resources/python"
else
    bash "$here/packaging/collect-licenses.sh" "$app/Contents/Resources/Licenses" "$sparkle_license"
fi

# 5. Sign Sparkle inside out (its prebuilt signature has the hardened runtime flag: --options=0
# drops it, D14), then the app (no --deep, no hardened runtime), and check it.
sparkle=$frameworks/Sparkle.framework/Versions/B
for item in "$sparkle/Updater.app" "$sparkle/Autoupdate" "$frameworks/Sparkle.framework"; do
    codesign --force -s - --timestamp=none --options=0 "$item"
done
codesign --force -s - --timestamp=none "$app"
codesign --verify --deep --strict "$app"

echo "Created $app ($mode, $config, version $version, $(du -sh "$app" | cut -f1))"
