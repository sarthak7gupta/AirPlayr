#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Developer-only regeneration. Normal tests use checked-in fixtures and need no ffmpeg install.
fixture_dir=AirPlayrTests/Fixtures
mkdir -p "$fixture_dir/Containers" "$fixture_dir/Audio"
for codec in h264 h265; do
    ffmpeg -hide_banner -loglevel error -nostdin -y -i "$fixture_dir/Big Buck Bunny 1080p_$codec.mp4" -map 0:v:0 -c copy -an -f matroska "$fixture_dir/Containers/Bunny-$codec.mkv"
    tag=avc1
    if [[ "$codec" == h265 ]]; then tag=hev1; fi
    ffmpeg -hide_banner -loglevel error -nostdin -y -i "$fixture_dir/Big Buck Bunny 1080p_$codec.mp4" -map 0:v:0 -c copy -tag:v "$tag" -an -f mov "$fixture_dir/Containers/Bunny-$codec.mov"
    ffmpeg -hide_banner -loglevel error -nostdin -y -i "$fixture_dir/Big Buck Bunny 1080p_$codec.mp4" -map 0:v:0 -c copy -tag:v "$tag" -an -brand 'M4V ' -f mp4 "$fixture_dir/Containers/Bunny-$codec.m4v"
done
ffmpeg -hide_banner -loglevel error -nostdin -y -i "$fixture_dir/Big Buck Bunny 1080p_h265.mp4" -i "$fixture_dir/Tracks.mp4" -map 0:v:0 -map 1:s -c copy -tag:v hev1 -f mp4 "$fixture_dir/Containers/Bunny-hev1-tracks.mp4"
for kind in wav m4a aac mp3 aiff caf flac; do
    case "$kind" in
        wav|caf) encoder=pcm_s16le ;;
        aiff) encoder=pcm_s16be ;;
        m4a|aac) encoder=aac ;;
        mp3) encoder=libmp3lame ;;
        flac) encoder=flac ;;
    esac
    ffmpeg -hide_banner -loglevel error -nostdin -y -f lavfi -i 'sine=frequency=440:duration=3:sample_rate=48000' -c:a "$encoder" "$fixture_dir/Audio/Tone.$kind"
done
