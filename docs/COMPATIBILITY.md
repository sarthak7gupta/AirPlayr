# Media & Receiver Compatibility

AirPlayr combines Apple's hardware media engines (`AVFoundation` and `VideoToolbox`) with a sandboxed, minimal LGPL FFmpeg remux bridge for Matroska (`.mkv`) containers.

## Supported Video Containers & Codecs

| Container | H.264 (AVC) | HEVC (H.265) | Notes |
| --- | --- | --- | --- |
| **MP4 (`.mp4`)** | ✓ Direct / HLS | ✓ Direct / HLS | Automatic normalization for `hev1`-tagged HEVC |
| **M4V (`.m4v`)** | ✓ Direct / HLS | ✓ Direct / HLS | Native Apple playback and AirPlay |
| **QuickTime (`.mov`)** | ✓ Direct / HLS | ✓ Direct / HLS | Native Apple playback and AirPlay |
| **Matroska (`.mkv`)** | ✓ MKV Bridge + HLS | ✓ MKV Bridge + HLS | On-demand 6-second section remux |

## Supported Audio Formats

- Standalone audio playback and AirPlay audio streaming: **WAV, AAC, M4A, MP3, AIFF, CAF, and FLAC** (with embedded artwork display).
- Multi-language audio track selection during video playback and TV streaming (`AAC`, `AC3`, `EAC3`, `MP3`, `FLAC`, `Opus`, `Vorbis`, `ALAC`, `PCM`).

## Supported Subtitle Formats

- External `.srt` (SubRip) in UTF-8 and BOM UTF-16 (up to 5 MB), with automatic matching-filename discovery.
- Embedded `subrip` in `.mkv` and MPEG-4 Timed Text (`tx3g` / `mov_text`) in `.mp4`/`.m4v`/`.mov`.
- Delivered to TVs as selectable **WebVTT** tracks or optional **pixel burn-in** with customizable font size, width, background style, and vertical position.

## Supported Wireless Protocols

- **Apple AirPlay & AirPlay 2** (Apple TV, HomePod, and AirPlay-enabled smart TVs)
- **Google Chromecast** (`_googlecast._tcp` Bonjour discovery + CastV2 TLS/Protobuf control channel on port 8009)
- **Miracast / DLNA (`UPnP AVTransport`)** (SSDP discovery + SOAP `AVTransport` control, plus macOS Wireless Display link)

## System Requirements

AirPlayr ships as a universal binary (`arm64` + `x86_64`) for Apple Silicon and Intel Macs (macOS 14+), with a companion native target for **iOS & iPadOS** (`platforms/ios`) and a **100% Client-Side Web Player** (`website/web-player.html`). Experimental desktop (Windows, Linux) and Android implementations are maintained on the `alpha` branch.

## Request for Community Testing (Input Clients & Output Receivers)

We welcome real-world test reports across different client operating systems, foldable/dual-screen devices, and Smart TV models (Apple TV, AirPlay 2 TVs, Chromecast / Google TV, and DLNA / Miracast UPnP Smart TVs):

- **[Submit a Device & TV Compatibility Test Report on GitHub](https://github.com/sarthak7gupta/AirPlayr/issues/new?template=device_testing_report.yml)**
