#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then echo "Usage: $0 APP_PATH OUTPUT_DMG" >&2; exit 2; fi
app=$1
output=$2
if [[ ! -d "$app" ]]; then echo 'Build AirPlayr first: task build' >&2; exit 1; fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" != com.airplayr.app ]]; then
    echo 'The source is not an AirPlayr application.' >&2; exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :AirPlayrBuildConfiguration' "$app/Contents/Info.plist")" != Release ]]; then
    echo 'Distribution requires the Release app, not the Debug test host.' >&2; exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app"
/bin/mkdir -p "$(/usr/bin/dirname "$output")"
stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/airplayr-dmg.XXXXXX")
trap '/bin/rm -rf "$stage"' EXIT
/usr/bin/ditto "$app" "$stage/AirPlayr.app"
/bin/ln -s /Applications "$stage/Applications"
project_root=$(cd "$(/usr/bin/dirname "$0")/.." && pwd)
offer="$stage/Open Source/FFmpeg"
/bin/mkdir -p "$offer/scripts" "$offer/Vendor/FFmpeg"
/usr/bin/ditto "$project_root/Vendor/FFmpeg/Source" "$offer/Vendor/FFmpeg/Source"
/usr/bin/ditto "$project_root/Vendor/FFmpeg/Licenses" "$offer/Vendor/FFmpeg/Licenses"
/bin/cp "$project_root/scripts/build-media-tools.sh" "$offer/scripts/build-media-tools.sh"
printf '%s\n' 'FFmpeg 9.0.2 LGPL helpers: complete source, configuration, licenses and build recipe.' 'From this folder on macOS with Xcode: /bin/bash scripts/build-media-tools.sh' > "$offer/README.txt"
/usr/bin/hdiutil create -volname AirPlayr -srcfolder "$stage" -format UDZO -fs HFS+ -ov "$output"
/usr/bin/hdiutil verify "$output"
printf 'Created: %s\n' "$output"
printf '%s\n' 'For public distribution, sign with Developer ID and notarize/staple this DMG. See docs/DISTRIBUTION.md.'
