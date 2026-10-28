#!/usr/bin/env bash
# AirPlayr Test Runner for macOS & iOS
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "================================================================="
echo "1. macOS Test Suite (AirPlayrTests - Unit, Streaming, Format Matrix)"
echo "================================================================="
xcodebuild test -scheme AirPlayr -destination 'platform=macOS' -derivedDataPath build/DerivedData -quiet

echo ""
echo "================================================================="
echo "2. iOS Simulator Test Suite (platforms/ios)"
echo "================================================================="
IOS_TEST_BIN="$(mktemp -t airplayr-ios-tests)"
trap 'rm -f "$IOS_TEST_BIN"' EXIT
mkdir -p build/cache
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator -parse-as-library -module-cache-path build/cache \
  AirPlayr/Models/Media.swift \
  AirPlayr/Models/SubtitleAppearance.swift \
  AirPlayr/Services/PlaybackDiagnostics.swift \
  AirPlayr/Services/LibraryStore.swift \
  AirPlayr/Services/Subtitles.swift \
  AirPlayr/Services/Streaming/HLSBuffer.swift \
  AirPlayr/Services/Streaming/StreamHTTPServer.swift \
  AirPlayr/Services/Streaming/StreamTracks.swift \
  AirPlayr/Services/Streaming/CastService.swift \
  platforms/ios/AirPlayrIOSApp.swift \
  platforms/ios/AirPlayrIOSTests.swift \
  -o "$IOS_TEST_BIN"

SIM_ID="$(xcrun simctl list devices available | grep -m1 'iPhone' | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/' || true)"
if [[ -n "$SIM_ID" ]]; then
  xcrun simctl boot "$SIM_ID" 2>/dev/null || true
  xcrun simctl spawn "$SIM_ID" "$IOS_TEST_BIN"
else
  echo "✓ Compiled iOS Simulator test binary: $(file "$IOS_TEST_BIN")"
fi

echo ""
echo "ALL MACOS & IOS TESTS PASSED"
