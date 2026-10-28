# Test Media Fixtures

All unit tests in `AirPlayrTests` load media exclusively from this folder inside the XCTest bundle. Fixtures are never packaged into `AirPlayr.app` or release DMGs.

## Included Fixtures

- `Big Buck Bunny 1080p_*.mp4` / `.mkv`: 10-second silent 1920×1080 test clips (`H.264`, `HEVC`, `AV1`) with SHA-256 checksums recorded in `manifest.json`. (`Big Buck Bunny 1080p_h264.mkv` is an ISO BMFF/MP4 file with a `.mkv` extension used to test mislabeled container detection.)
- `Containers/Bunny-h264.mkv`, `Bunny-h265.mkv`: Genuine Matroska (`EBML`) stream-copy remuxes.
- `Containers/Bunny-*.mov`, `Containers/Bunny-*.m4v`: QuickTime MOV and M4V-branded remuxes (`hev1` tags retained to exercise automatic normalization).
- `Containers/Bunny-hev1-tracks.mp4`: HEVC video with two embedded MPEG-4 Timed Text subtitle tracks.
- `Audio/Tone.*`: Synthetic 3-second sine tones in `WAV`, `AAC`, `M4A`, `MP3`, `AIFF`, `CAF`, and `FLAC`.
- `Video.mp4`, `Tracks.mp4`, `HEVC.mkv`: Synthetic fixtures for pixel assertions, cue boundaries, multi-track selection, and cancellation tests.

## Attribution

The *Big Buck Bunny* test clips and container remuxes are excerpts of *Big Buck Bunny*:

- (c) copyright 2008, Blender Foundation / [www.bigbuckbunny.org](https://peach.blender.org/about/)
- Licensed under [Creative Commons Attribution 3.0 Unported (CC-BY 3.0)](https://creativecommons.org/licenses/by/3.0/).
