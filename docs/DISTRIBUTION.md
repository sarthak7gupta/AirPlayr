# Build, Install & Release Guide

## Prerequisites

- macOS 15+ and Xcode (Command Line Tools installed)
- Optional: [Task](https://taskfile.dev/) (`brew install go-task`) for shorthand commands

## Common Commands

```sh
task build           # Build universal (arm64 + x86_64) Release AirPlayr.app
task test            # Run the XCTest suite
task verify          # Verify macOS 27/26/15 + Beta compatibility & code signature
task install         # Build and install AirPlayr.app into /Applications
task dmg             # Package build/dist/AirPlayr-<version>.dmg
task media-tools     # Rebuild universal LGPL FFmpeg helpers from pinned source
```

Without `task`, you can run the underlying scripts directly:

```sh
xcodebuild -project AirPlayr.xcodeproj -scheme AirPlayr -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

./scripts/macos-compat-check.sh build/DerivedData/Build/Products/Release/AirPlayr.app
./scripts/create-dmg.sh build/DerivedData/Build/Products/Release/AirPlayr.app build/dist/AirPlayr-1.6.0.dmg
```

## Signing & Notarization for Public Releases

Local development builds use ad-hoc signing (`SIGNING_IDENTITY="-"`). To sign and notarize a release DMG with an Apple Developer ID certificate:

```sh
task dmg TEAM_ID=YOURTEAMID 'SIGNING_IDENTITY=Developer ID Application: Your Name (YOURTEAMID)'
xcrun notarytool submit build/dist/AirPlayr-1.6.0.dmg --keychain-profile AirPlayrNotary --wait
xcrun stapler staple build/dist/AirPlayr-1.6.0.dmg
./scripts/release-check.sh build/DerivedData/Build/Products/Release/AirPlayr.app
```
