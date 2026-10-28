#!/bin/bash
set -euo pipefail
app=${1:?Pass the Release app path}
/bin/bash "$(dirname "$0")/macos-compat-check.sh" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
signature=$(/usr/bin/codesign -dvv "$app" 2>&1)
if ! /usr/bin/grep -F 'Authority=Developer ID Application:' <<< "$signature" >/dev/null; then
    echo 'NOT READY: the app is not signed with Developer ID Application.' >&2; exit 1
fi
if ! /usr/bin/grep -E 'flags=.*runtime' <<< "$signature" >/dev/null; then
    echo 'NOT READY: hardened runtime is missing.' >&2; exit 1
fi
stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/airplayr-release-check.XXXXXX")
trap '/bin/rm -rf "$stage"' EXIT
/usr/bin/codesign -d --entitlements - --xml "$app" > "$stage/entitlements.plist"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$stage/entitlements.plist" 2>/dev/null || true)" == true ]]; then
    echo 'NOT READY: debug get-task-allow entitlement is present.' >&2; exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$stage/entitlements.plist")" != true ]]; then
    echo 'NOT READY: App Sandbox is missing.' >&2; exit 1
fi
/usr/sbin/spctl --assess --type execute --verbose=4 "$app"
echo 'Developer ID, runtime, sandbox, and Gatekeeper assessment passed.'
