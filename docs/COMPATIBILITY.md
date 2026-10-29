# Media & Receiver Compatibility

AirPlayr combines Apple's hardware media engines (`AVFoundation` and `VideoToolbox`) with a sandboxed, minimal LGPL FFmpeg remux bridge for Matroska (`.mkv`), transport streams, and optical disc media.

## Supported Video Containers & Codecs

| Container | H.264 (AVC) | HEVC (H.265) | MPEG-2 / AV1 | Platform | Notes |
| --- | --- | --- | --- | --- | --- |
| **MP4 (`.mp4`)** | ✓ Direct / HLS | ✓ Direct / HLS | ✓ AV1 (M1+) | macOS & iOS | Automatic normalization for `hev1`-tagged HEVC |
| **M4V (`.m4v`)** | ✓ Direct / HLS | ✓ Direct / HLS | — | macOS & iOS | Native Apple playback and AirPlay |
| **QuickTime (`.mov`)** | ✓ Direct / HLS | ✓ Direct / HLS | — | macOS & iOS | Native Apple playback and AirPlay |
| **Matroska (`.mkv`)** | ✓ MKV Bridge + HLS | ✓ MKV Bridge + HLS | ✓ AV1 Bridge | macOS & iOS | On-demand 6-second section remux |
| **BDAV / Transport (`.m2ts`, `.ts`, `.mts`)** | ✓ Stream Copy | ✓ Stream Copy | — | macOS | Blu-ray & AVCHD streams direct fMP4 remux |
| **HLS Playlist (`.m3u8`)** | ✓ Native AVPlayer | ✓ Native AVPlayer | — | macOS | Master and media playlist streaming |
| **DVD Video Object (`.vob`)** | — | — | ✓ Transcoded | macOS | MPEG-2 video re-encoded to fast H.264; AC-3 audio preserved |
| **Disc Images (`.iso`)** | ✓ Auto-Mount | ✓ Auto-Mount | ✓ Auto-Mount | macOS | Auto-mounts via `hdiutil`, scans `BDMV/STREAM` & `VIDEO_TS` |

## Supported Audio & Multichannel Passthrough

- **Full Multichannel Surround Sound**: Bit-perfect 5.1 (`kAudioChannelLayoutTag_MPEG_5_1_D`) and 7.1 (`kAudioChannelLayoutTag_MPEG_7_1_B`) channel passthrough without downmixing to stereo.
- **Dolby Formats**: Dolby Digital (`AC-3`), Dolby Digital Plus (`E-AC-3`), Dolby TrueHD passthrough, and Dolby AC-4 (`.ac4`) demuxing.
- **DTS Formats**: DTS Digital Surround and DTS-HD Master Audio passthrough.
- **Standalone Audio**: **WAV, AAC, M4A, MP3, AIFF, CAF, and FLAC** with embedded metadata and album art.

## HDR & Advanced Video Capabilities

- **10-bit HEVC & HDR10**: Full dynamic range passthrough with zero re-encoding or bit-depth loss.
- **Dolby Vision**: Profile 5 and Profile 8.1 metadata preservation via stream copy into fMP4 segments.
- **Instant fMP4 In-Memory Remuxing**: Zero-latency transport stream generation over local Wi-Fi.

## Supported Subtitle Formats

- External `.srt` (SubRip) in UTF-8 and BOM UTF-16 (up to 5 MB), with automatic matching-filename discovery.
- Embedded `subrip` in `.mkv` and MPEG-4 Timed Text (`tx3g` / `mov_text`) in `.mp4`/`.m4v`/`.mov`.
- Delivered to TVs as selectable **WebVTT** tracks or optional **pixel burn-in** with customizable font size, width, background style, and vertical position.

## Supported Wireless Protocols

- **Apple AirPlay & AirPlay 2** (Apple TV, HomePod, and AirPlay-enabled smart TVs with video & audio hardware synchronization)
- **Google Chromecast** (`_googlecast._tcp` Bonjour discovery + CastV2 TLS/Protobuf control channel on port 8009)
- **Miracast / DLNA (`UPnP AVTransport`)** (SSDP discovery + SOAP `AVTransport` control, plus macOS Wireless Display link)

## System Requirements

AirPlayr ships as a universal binary (`arm64` + `x86_64`) for Apple Silicon and Intel Macs (macOS 14+), with a companion native target for **iOS & iPadOS** (`platforms/ios`) and a **100% Client-Side Web Player** (`website/web-player.html`).

## Request for Community Testing (Input Clients & Output Receivers)

We welcome real-world test reports across different client operating systems and Smart TV models:

- **[Submit a Device & TV Compatibility Test Report on GitHub](https://github.com/sarthak7gupta/AirPlayr/issues/new?template=device_testing_report.yml)**
