#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then echo "Usage: $0 APP_PATH INSTALL_DIRECTORY" >&2; exit 2; fi
app=$1
install_dir=$2
destination="$install_dir/AirPlayr.app"
if [[ ! -d "$app" ]]; then echo 'Build AirPlayr first: task build' >&2; exit 1; fi
if [[ "$install_dir" != /* ]]; then echo 'INSTALL_DIR must be an absolute path.' >&2; exit 1; fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" != com.airplayr.app ]]; then
    echo 'The source is not an AirPlayr application.' >&2; exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app"
if [[ -e "$destination" ]]; then
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)" != com.airplayr.app ]]; then
        echo "Refusing to replace an unrelated item: $destination" >&2; exit 1
    fi
    if ! processes=$(/bin/ps -axo comm=); then
        echo 'Could not check whether the installed app is running. Installation stopped.' >&2; exit 1
    fi
    if /usr/bin/grep -Fx "$destination/Contents/MacOS/AirPlayr" <<< "$processes" >/dev/null; then
        echo 'Quit the installed AirPlayr before updating it. Playback is not stopped automatically.' >&2; exit 1
    fi
fi
if ! /bin/mkdir -p "$install_dir" || [[ ! -w "$install_dir" ]]; then
    echo 'Installation needs permission. Run task build, then run the installer helper with administrator permission (see docs/DISTRIBUTION.md).' >&2; exit 1
fi
stage=$(/usr/bin/mktemp -d "$install_dir/.airplayr-install.XXXXXX")
cleanup() {
    if [[ -d "$stage/Previous.app" && ! -e "$destination" ]]; then /bin/mv "$stage/Previous.app" "$destination"; fi
    /bin/rm -rf "$stage"
}
trap cleanup EXIT
/usr/bin/ditto "$app" "$stage/AirPlayr.app"
/usr/bin/codesign --verify --deep --strict "$stage/AirPlayr.app"
if [[ -e "$destination" ]]; then /bin/mv "$destination" "$stage/Previous.app"; fi
/bin/mv "$stage/AirPlayr.app" "$destination"
printf 'Installed: %s\n' "$destination"
