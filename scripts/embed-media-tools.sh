#!/bin/bash
set -euo pipefail
source_dir="$SRCROOT/Vendor/FFmpeg"
output_dir="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
license_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/FFmpegLicenses"
mkdir -p "$output_dir" "$license_dir"
for tool in ffmpeg ffprobe; do
    if [[ ! -x "$source_dir/bin/$tool" ]]; then echo 'Run task media-tools first to build the bundled MKV helpers.' >&2; exit 1; fi
    /usr/bin/ditto "$source_dir/bin/$tool" "$output_dir/$tool"
    identity=${EXPANDED_CODE_SIGN_IDENTITY:--}
    if [[ -z "$identity" ]]; then identity=-; fi
    if [[ "$identity" != - ]]; then
        /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$SRCROOT/AirPlayr/Resources/MediaTool.entitlements" "$output_dir/$tool"
    else
        /usr/bin/codesign --force --sign - --options runtime --entitlements "$SRCROOT/AirPlayr/Resources/MediaTool.entitlements" "$output_dir/$tool"
    fi
done
/usr/bin/ditto "$source_dir/Licenses" "$license_dir"
