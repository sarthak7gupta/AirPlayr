import AVFoundation

// MARK: - HLS alternate audio and WebVTT subtitle renditions

/// Describes one selectable audio rendition in the TV compatibility master playlist.
struct StreamAudioTrack: Sendable {
    let index: Int
    let name: String
    let language: String
    let described: Bool
}
/// One WebVTT-backed subtitle offered to the TV HLS player.
struct StreamSubtitleTrack: Sendable {
    let name: String
    let language: String
    let document: SubtitleDocument
    let accessibility: Bool
    let forced: Bool
}
/// Audio/subtitle tracks discovered for a compatibility stream, plus non-fatal notices.
struct StreamTracks: Sendable {
    var audio: [StreamAudioTrack] = []
    var subtitles: [StreamSubtitleTrack] = []
    var notices: [String] = []

    static func inspect(source: URL, external: SubtitleDocument?) async throws -> StreamTracks {
        let access = FileAccess(source)
        defer { withExtendedLifetime(access) {} }
        let asset = AVURLAsset(url: source)
        var result = StreamTracks()
        for (index, track) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
            guard index < 32 else { result.notices.append("Only the first 32 audio tracks are offered for TV playback."); break }
            let tag = try? await track.load(.extendedLanguageTag)
            let code = try? await track.load(.languageCode)
            let language = tag ?? code ?? "und"
            let characteristics = try await track.load(.mediaCharacteristics)
            let label = Locale.current.localizedString(forIdentifier: language) ?? "Audio"
            result.audio.append(StreamAudioTrack(index: index, name: "\(label) · \(index + 1)", language: language, described: characteristics.contains(.describesVideoForAccessibility)))
        }
        let subtitleTracks = try await asset.loadTracks(withMediaType: .subtitle)
        let textTracks = try await asset.loadTracks(withMediaType: .text)
        let tracks = subtitleTracks + textTracks
        for (index, track) in tracks.enumerated() {
            guard index < 32 else { result.notices.append("Only the first 32 subtitle tracks are offered for TV playback."); break }
            let formats = try await track.load(.formatDescriptions)
            guard formats.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMTextFormatType_3GText }), !formats.isEmpty else {
                result.notices.append("Subtitle track \(index + 1) cannot be converted for the TV. Use an external SRT; only embedded MPEG-4 timed text is currently supported."); continue
            }
            do {
                let document = try await readTimedText(asset: asset, track: track)
                let tag = try? await track.load(.extendedLanguageTag)
            let code = try? await track.load(.languageCode)
            let language = tag ?? code ?? "und"
            let characteristics = try await track.load(.mediaCharacteristics)
                let label = Locale.current.localizedString(forIdentifier: language) ?? "Subtitles"
                result.subtitles.append(StreamSubtitleTrack(name: "\(label) · \(index + 1)", language: language, document: document, accessibility: characteristics.contains(.describesMusicAndSoundForAccessibility), forced: characteristics.contains(.containsOnlyForcedSubtitles)))
            } catch is CancellationError { throw CancellationError() }
            catch { result.notices.append("Subtitle track \(index + 1) could not be read for the TV. Load an external SRT instead.") }
        }
        if let external { result.subtitles.append(StreamSubtitleTrack(name: "External SRT", language: "und", document: external, accessibility: false, forced: false)) }
        return result
    }
    private static func readTimedText(asset: AVAsset, track: AVAssetTrack) async throws -> SubtitleDocument {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw MediaIssue.unsupported }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaIssue.unsupported }
        defer { reader.cancelReading() }
        var cues: [SubtitleCue] = [], bytes = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            bytes += length
            guard length >= 2, bytes <= 5_000_000, cues.count < 100_000 else { throw MediaIssue.subtitles("Embedded subtitle data exceeds the supported size.") }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let address = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: address)
            }
            guard status == kCMBlockBufferNoErr else { throw MediaIssue.unsupported }
            let textLength = Int(data[0]) << 8 | Int(data[1])
            guard textLength <= length - 2 else { throw MediaIssue.unsupported }
            if textLength == 0 { continue }
            let payload = data.subdata(in: 2..<(2 + textLength))
            let encoding: String.Encoding = payload.starts(with: [0xfe, 0xff]) || payload.starts(with: [0xff, 0xfe]) ? .utf16 : .utf8
            guard let text = String(data: payload, encoding: encoding) else { throw MediaIssue.unsupported }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let end = start + CMSampleBufferGetDuration(sample).seconds
            guard start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        if let error = reader.error { throw error }
        return SubtitleDocument(cues: cues)
    }
    static func attribute(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 && $0 != "\"" && $0 != "\\" }.prefix(160))
    }
    func master() -> Data {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        if audio.count > 1 {
            for track in audio {
                var line = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(Self.attribute(track.name))\",LANGUAGE=\"\(Self.attribute(track.language))\",AUTOSELECT=YES,DEFAULT=\(track.index == 0 ? "YES" : "NO"),CHANNELS=\"2\""
                if track.index != 0 { line += ",URI=\"a\(track.index).m3u8\"" }
                if track.described { line += ",CHARACTERISTICS=\"public.accessibility.describes-video\"" }
                lines.append(line)
            }
        }
        for (index, track) in subtitles.enumerated() {
            var line = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(Self.attribute(track.name))\",LANGUAGE=\"\(Self.attribute(track.language))\",AUTOSELECT=YES,DEFAULT=NO,FORCED=\(track.forced ? "YES" : "NO"),URI=\"t\(index).m3u8\""
            if track.accessibility { line += ",CHARACTERISTICS=\"public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound\"" }
            lines.append(line)
        }
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=4200000" + (audio.count > 1 ? ",AUDIO=\"audio\"" : "") + (!subtitles.isEmpty ? ",SUBTITLES=\"subs\"" : ""))
        lines.append("media.m3u8")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
    static func webVTT(_ document: SubtitleDocument, start: Double, end: Double) -> Data {
        func stamp(_ seconds: Double) -> String {
            let ms = Int((max(0, seconds) * 1000).rounded())
            return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var text = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n"
        for cue in document.cues where cue.end > start && cue.start < end {
            let escaped = cue.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            text += "\(stamp(cue.start)) --> \(stamp(cue.end))\n\(escaped)\n\n"
        }
        return Data(text.utf8)
    }
}
