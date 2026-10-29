#!/usr/bin/env bash
# AirPlayr Test Runner for macOS
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "================================================================="
echo "macOS Test Suite (AirPlayrTests - Unit, Streaming, Format Matrix)"
echo "================================================================="
xcodebuild test -scheme AirPlayr -destination 'platform=macOS' -derivedDataPath build/DerivedData -quiet

echo ""
echo "ALL MACOS TESTS PASSED"
