#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=9.0.2
archive="Vendor/FFmpeg/Source/ffmpeg-$version.tar.xz"
expected=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
actual=$(/usr/bin/shasum -a 256 "$archive")
[[ "${actual%% *}" == "$expected" ]] || { echo 'FFmpeg source checksum mismatch.' >&2; exit 1; }
mkdir -p build/media-tools Vendor/FFmpeg/bin
if [[ ! -d "build/ffmpeg-$version" ]]; then /usr/bin/tar -xf "$archive" -C build; fi
project_root="$PWD"
for architecture in arm64 x86_64; do
    mkdir -p "build/media-tools/$architecture"
    cd "build/media-tools/$architecture"
    if [[ ! -f ffbuild/config.mak ]] || [[ ! -e Makefile ]] || ! /usr/bin/grep -q "^#define CONFIG_MOVTEXT_DECODER 1$" config_components.h || ! /usr/bin/grep -q "^#define CONFIG_ASS_DECODER 1$" config_components.h || ! /usr/bin/grep -q "^#define CONFIG_AV1_PARSER 1$" config_components.h; then
        /bin/rm -f Makefile
        "$project_root/build/ffmpeg-$version/configure" \
            --enable-cross-compile --target-os=darwin --arch="$architecture" --cc=clang \
            --extra-cflags="-arch $architecture -mmacosx-version-min=14.0" \
            --extra-ldflags="-arch $architecture -mmacosx-version-min=14.0" \
            --disable-gpl --disable-nonfree --disable-autodetect --disable-network \
            --disable-everything --disable-shared --enable-static --disable-doc --disable-debug \
            --disable-x86asm --enable-small --enable-ffmpeg --enable-ffprobe \
            --enable-protocol=file,pipe,fd --enable-demuxer=matroska,mov,srt,ass \
            --enable-muxer=mp4,srt --enable-parser=hevc,h264,av1,aac,ac3,flac,mpegaudio,opus,vorbis \
            --enable-decoder=aac,aac_latm,ac3,eac3,mp3,mp3float,flac,opus,vorbis,pcm_s16le,subrip,movtext,ass,ssa \
            --enable-encoder=aac,subrip --enable-filter=aresample,anull,aformat,atrim,asetpts \
            --enable-bsf=hevc_mp4toannexb,h264_mp4toannexb,aac_adtstoasc,extract_extradata,av1_metadata
    fi
    /usr/bin/make -j8 ffmpeg ffprobe
    cd "$project_root"
done
for tool in ffmpeg ffprobe; do
    /usr/bin/lipo -create "build/media-tools/arm64/$tool" "build/media-tools/x86_64/$tool" -output "Vendor/FFmpeg/bin/$tool"
    /usr/bin/strip -x "Vendor/FFmpeg/bin/$tool"
done
cp build/media-tools/arm64/config.h Vendor/FFmpeg/Source/config-arm64.h
cp build/media-tools/x86_64/config.h Vendor/FFmpeg/Source/config-x86_64.h
Vendor/FFmpeg/bin/ffmpeg -version
