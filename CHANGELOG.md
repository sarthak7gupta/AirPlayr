# Changelog

All notable changes to **AirPlayr** are documented in this file.
AirPlayr follows semantic versioning (`MAJOR.MINOR.PATCH`) and ships across macOS (`arm64` + `x86_64`), Windows, Linux, iOS/iPadOS, Android, and Web.

## [1.7.0] - 2026-10-27

### Added
- **Zero-Re-Encode 1080p / 4K Video Passthrough (`IncrementalEncoder.tryPassthroughEncode`):**
  - Directly muxes compressed H.264 (`avc1`) and HEVC (`hvc1`) video samples into `fMP4` HLS segments (`outputSettings: nil`) when no subtitle burn-in is active and the segment begins on a sync keyframe.
  - Preserves native resolution up to **4K (`3840×2160`)** with adaptive bitrate scaling (`3.5 Mbps` / `6.5 Mbps` / `12 Mbps`) when hardware `VideoToolbox` encoding is used.
- **Playlists & Up Next Queue (`⌘[` / `⌘]`):**
  - Multi-file and folder selection in Open panels and drag-and-drop expands supported media files in natural sort order into an **Up Next Queue** with sidebar queue management, Previous/Next buttons (`⌘[` / `⌘]`), and automatic advance on track completion.
- **Live Subtitle Sync Offset (`±0.25s`) & Preferred Audio/Subtitle Languages:**
  - Real-time `±0.25s` subtitle timing adjustment (`SubtitleDocument.shifted(by:)`) for both local overlays and TV compatibility streams.
  - Persisted preferred audio and subtitle language codes (`UserDefaults`) with automatic track selection on media open.
- **macOS Media Keys, Control Center & AirPods Remote Control:**
  - Integrated `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for hardware play/pause, skip forward/backward, next/previous track, and timeline scrubbing from Control Center and AirPods.
- **Automatic SSDP Multicast Discovery for Miracast / DLNA TVs:**
  - Sends UDP `M-SEARCH` multicast discovery (`239.255.255.250:1900`) for `MediaRenderer:1` and `AVTransport:1`, parses UPnP device XML descriptions, and populates discovered Smart TVs automatically in the Cast menu.
- **Embedded ASS / SSA Subtitle Extraction & AV1 Hardware Decode:**
  - Enabled `ass`/`ssa` demuxers/decoders and `av1` parser/`av1_metadata` bitstream filter in `scripts/build-media-tools.sh` + `MKVBridge.swift`, stripping ASS override tags (`{\an8}`, `\N`) into clean WebVTT/SRT cues and enabling hardware-accelerated AV1 streaming on M3/M4+ Macs.
- **Opt-In OpenSubtitles Search & Download (`OpenSubtitlesService` / `OpenSubtitlesSheet`):**
  - Computes the standard 64-bit OpenSubtitles movie hash locally (`fileSize + first 64 KB + last 64 KB`), stores user API keys in the macOS Keychain, and downloads matching `.srt` captions on demand.
- **Cross-Platform & Dual-Screen / Foldable Support (`platforms/` & `website/web-player.html`):**
  - Added **Windows & Linux** desktop engine (`platforms/desktop/airplayr_desktop.py` + 10 unit tests), **iOS / iPadOS / iPhone Fold** target (`platforms/ios/AirPlayrIOSApp.swift` + 6 iOS Simulator tests), **Android & Foldable** Jetpack Compose + Media3 app (`platforms/android/` + 6 tests on JVM & Android Emulator), and a **100% Client-Side Web Player** (`website/web-player.html`) with Tabletop and Book dual-screen postures.

## [1.6.0] - 2026-10-27

### Added
- **Chromecast & Miracast / DLNA Support (`CastService`):**
  - Automatic local network discovery for Chromecast devices (`_googlecast._tcp` via `NWBrowser`) and native CastV2 TLS/Protobuf media control (`LAUNCH`, `LOAD`, `PLAY`, `PAUSE`, `SEEK`, `STOP`) on port `8009`.
  - Support for Miracast / DLNA network media renderers via `UPnP AVTransport` SOAP commands (`SetAVTransportURI`, `Play`, `Pause`, `Seek`, `Stop`) and manual receiver IP/port connection sheet.
  - Quick shortcut to macOS Wireless Display / Screen Mirroring settings for hardware Wi-Fi Direct Miracast sinks.
- **Prevent Computer from Sleeping While Playing:**
  - Added user setting (**Settings → Prevent Mac from sleeping while a file is playing** and **Playback → Prevent Mac from Sleeping While Playing**, enabled by default) backed by `IOKit` `kIOPMAssertionTypePreventUserIdleDisplaySleep`.
  - Automatically acquires the power assertion during active local playback, TV preparation, AirPlay routing, and Cast sessions, and releases it immediately on pause, stop, or completion.
- **Rolling 3-Version macOS Compatibility Verification (`scripts/macos-compat-check.sh`):**
  - Automated build and release check ensuring universal (`arm64` + `x86_64`) binaries and `LSMinimumSystemVersion` / `minos` compatibility across **macOS 27, macOS 26, macOS 15**, and the **latest macOS Public Beta**.
- **Startup Crash-Residue Cache Cleanup (`TemporaryCacheCleanup`):**
  - Automatically removes any orphaned `AirPlayr-VOD-*`, `AirPlayr-MKV-*`, and `AirPlayr-Export-*` temporary directories left behind by a prior crash or force-quit.

### Fixed & Hardened
- **MKV Multi-Audio & Timed-Text Reliability:**
  - `MKVBridge.section` now maps only the active audio stream (`-map 0:a:<index>?`) instead of all audio streams (`-map 0:a?`), preventing unsupported secondary audio tracks (e.g., DTS/TrueHD) from failing playback and reducing per-segment CPU usage.
  - Fixed `movtext` decoder configuration in `scripts/build-media-tools.sh` so embedded MP4/MOV `mov_text` (`tx3g`) subtitles are extracted cleanly during `hev1` normalization.
  - Eliminated redundant per-segment `ffprobe` and `AVURLAsset.load(.isPlayable)` inspections in `VODStreamStore` / `IncrementalEncoder`.
- **Subprocess & Stream Cancellation Safety:**
  - Serialized `AVAssetReader.cancelReading()` after reader pump completion in `WriterLifetime` to prevent concurrent `FigAssetReader` teardown races during rapid seek/cancel cycles.
  - Fixed a `[weak self]` deallocation bug in `MediaToolRunner.Running` so `SIGKILL` escalation is guaranteed to fire if a timed-out or cancelled `ffmpeg`/`ffprobe` process ignores `SIGTERM`, and ensured `waitUntilExit()` always reaps child processes.
- **SRT Parser Resilience:**
  - `SubtitleDocument.parse` now tolerates empty spacer cues and WebVTT/SRT cue positioning tags on `-->` lines without rejecting the entire subtitle file.
- **Seek & Subtitle Loading State Machine:**
  - Avoided unnecessary `seek(to: 0)` when a fresh compatibility stream starts at `0s`, fixing headless video-only HLS readiness.
  - Cleared pending `streamStart` when a user explicitly seeks, and allowed loading external SRT files while TV stream preparation is in progress.
- **Network & ATS Hardening:**
  - Removed unnecessary global `NSAllowsArbitraryLoadsForMedia` from `Info.plist` while retaining `NSAllowsLocalNetworking`.
  - Prioritized physical `en0` / `en*` interfaces over virtual `bridge*` interfaces in `StreamHTTPServer.localAddress()`, and evicted unauthenticated idle connections when the 24-connection limit is reached.

## [1.5.0] - 2026-10-25

### Added
- Format matrix test suite verifying H.264 and HEVC across `.mp4`, `.mkv`, `.m4v`, and `.mov` containers, plus `WAV`, `AAC`, `M4A`, `MP3`, `AIFF`, `CAF`, and `FLAC` audio formats.
- Automatic `hev1` HEVC tag normalization for MP4/M4V/MOV files rejected by direct AirPlay.

## [1.4.0] - 2026-10-24

### Added
- Bundled universal LGPL FFmpeg 9.0.2 `ffmpeg` and `ffprobe` helpers for zero-Homebrew H.264/HEVC `.mkv` playback and TV streaming via read-only file descriptors (`fd:0`).
- Embedded MKV `subrip` extraction into selectable WebVTT TV subtitle tracks.

## [1.3.0] - 2026-10-23

### Added
- Selectable multi-language HLS audio renditions and WebVTT subtitle tracks on AirPlay receivers.
- Variable playback speed (`0.5×` to `4.0×` in `0.25×` increments) and window-scoped Spacebar play/pause handling.
- Full-duration VOD HLS playlists enabling arbitrary forward/backward seeking from both Mac and TV remotes.
