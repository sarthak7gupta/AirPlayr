# Security & Privacy Architecture

AirPlayr is architected as a local-first, sandboxed macOS application with zero telemetry, zero cloud accounts, and strict process and network boundaries.

## Core Security Controls

| Layer | Protection |
| --- | --- |
| **App Sandbox** | Enabled with `com.apple.security.app-sandbox`. Access is restricted to user-selected files (`files.user-selected.read-write` for exports, security-scoped bookmarks for Recents) and local network sockets (`network.client`, `network.server`). |
| **Subprocess Isolation** | Bundled `ffmpeg` and `ffprobe` binaries are compiled from pinned FFmpeg 9.0.2 source with all networking, external libraries, and autodetection disabled. Media is passed via read-only file descriptors (`fd:0`), never shell strings or file paths. Child processes are bounded by a 2 MB stdout cap and 30s timeout with `SIGTERM` → `SIGKILL` escalation. |
| **LAN HTTP Stream Server** | Binds only to the active private LAN IPv4 interface (`en0`/`en*`) on an ephemeral port. Every stream session generates a 64-character random bearer token. Only `GET` and `HEAD` requests for registered segment filenames are served; path traversal is rejected, headers are capped at 8 KiB with a 5s deadline, and unauthenticated idle sockets are evicted under connection pressure. |
| **App Transport Security (ATS)** | `NSAllowsLocalNetworking` is enabled strictly for local-network receiver communication; arbitrary clear-text internet loads are disabled. |
| **Temporary Cache Hygiene** | Compatibility HLS segments and MKV remux staging files are written to mode-`0700` temporary directories, deleted synchronously when playback stops, and swept on application launch via `TemporaryCacheCleanup.removeAbandonedCaches()`. |
| **Safe File Export** | `CompatibleExportService` encodes to a private temporary directory and uses `FileManager.copyItem` without overwriting existing destination files. |
| **Power Assertion Lifecycle** | When "Prevent Mac from sleeping while a file is playing" is active, `IOPMAssertionCreateWithName` (`kIOPMAssertionTypePreventUserIdleDisplaySleep`) is held only while video/audio is actively playing or casting and is released immediately on pause, stop, or app termination. |
