#!/bin/bash
set -euo pipefail
# Verify compatibility with the last 3 macOS major releases (currently macOS 27, 26, and 15)
# as well as forward compatibility with the latest macOS public beta.
app=${1:?Pass the built AirPlayr.app path}
max_supported_min_major=15

min_version=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
min_major=${min_version%%.*}
if (( min_major > max_supported_min_major )); then
    echo "INCOMPATIBLE: LSMinimumSystemVersion is $min_version (must be <= ${max_supported_min_major}.0 to support macOS 15, 26, 27, and public beta)." >&2
    exit 1
fi

for binary in "$app/Contents/MacOS/AirPlayr" "$app/Contents/MacOS/ffmpeg" "$app/Contents/MacOS/ffprobe"; do
    if [[ ! -x "$binary" ]]; then
        echo "MISSING EXECUTABLE: $binary" >&2
        exit 1
    fi
    archs=$(/usr/bin/lipo -archs "$binary")
    for required_arch in arm64 x86_64; do
        if [[ " $archs " != *" $required_arch "* ]]; then
            echo "INCOMPATIBLE ARCH: $binary is missing $required_arch (found: $archs)" >&2
            exit 1
        fi
    done
    while IFS= read -r minos; do
        major=${minos%%.*}
        if (( major > max_supported_min_major )); then
            echo "INCOMPATIBLE MINOS: $binary requires macOS $minos (must be <= ${max_supported_min_major}.0 for macOS 15, 26, 27, and beta)." >&2
            exit 1
        fi
    done < <(/usr/bin/vtool -show-build "$binary" | /usr/bin/awk '/minos/ {print $2}')
done

echo "macOS compatibility verified: universal (arm64 + x86_64), minOS $min_version (compatible with macOS 15, macOS 26, macOS 27, and latest macOS Public Beta)."
