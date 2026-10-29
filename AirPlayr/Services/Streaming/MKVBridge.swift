import AVFoundation
import VideoToolbox
import Darwin

/// Restricted, bundled command-line helpers. Arguments never pass through a shell.
enum MediaToolRunner {
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var timedOut = false
        func launch(_ process: Process) throws {
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                try process.run()
                self.process = process
            }
        }
        func cancel(timeout: Bool = false) {
            lock.withLock {
                cancelled = true; timedOut = timedOut || timeout
                guard let process, process.isRunning else { return }
                kill(process.processIdentifier, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.forceStop() }
            }
        }
        private func forceStop() {
            lock.withLock {
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        func finish() throws {
            try lock.withLock {
                process = nil
                if timedOut { throw StreamFailure(message: "Preparing this MKV section took too long. Try again or choose a different file.") }
                if cancelled { throw CancellationError() }
            }
        }
    }
    static func executable(_ name: String) throws -> URL {
        guard ["ffmpeg", "ffprobe"].contains(name), let url = Bundle.main.url(forAuxiliaryExecutable: name),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw StreamFailure(message: "The MKV playback helper is missing. Rebuild AirPlayr with task build or reinstall the complete app.")
        }
        return url
    }
    static func run(_ name: String, arguments: [String], input: URL? = nil, limit: Int = 5_000_000) async throws -> Data {
        let executable = try executable(name), running = Running()
        let inputHandle = try input.map { try FileHandle(forReadingFrom: $0) }
        defer { try? inputHandle?.close() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process(), pipe = Pipe()
                    process.qualityOfService = .userInitiated
                    process.executableURL = executable; process.arguments = arguments
                    process.standardInput = inputHandle ?? FileHandle.nullDevice
                    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                    let deadline = DispatchWorkItem { running.cancel(timeout: true) }
                    defer { deadline.cancel(); try? pipe.fileHandleForReading.close() }
                    do {
                        try running.launch(process)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
                        var output = Data()
                        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                            guard output.count + chunk.count <= limit else {
                                running.cancel()
                                try? pipe.fileHandleForReading.close()
                                process.waitUntilExit()
                                throw StreamFailure(message: "This file contains more metadata or subtitle data than the supported limit.")
                            }
                            output.append(chunk)
                        }
                        process.waitUntilExit()
                        try running.finish()
                        guard process.terminationStatus == 0 else {
                            throw StreamFailure(message: "This MKV could not be prepared for playback. Its video or audio may be unsupported or damaged. Try another file.")
                        }
                        continuation.resume(returning: output)
                    } catch {
                        running.cancel()
                        try? pipe.fileHandleForReading.close()
                        if process.isRunning { process.waitUntilExit() }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { running.cancel() }
    }
}

struct MKVMetadata: Decodable, Sendable {
    struct Format: Decodable, Sendable { let duration: String? }
    struct Track: Decodable, Sendable {
        let index: Int
        let codec_name: String?
        let codec_type: String?
        let channels: Int?
        let channel_layout: String?
        let width: Int?
        let height: Int?
        let tags: [String: String]?
    }
    let streams: [Track]
    let format: Format
    var duration: Double? {
        let container = format.duration.flatMap(Double.init)
        if let timestamp = video?.tags?["DURATION"] {
            let fields = timestamp.split(separator: ":").compactMap { Double($0) }
            if fields.count == 3 {
                let videoLength = fields[0] * 3600 + fields[1] * 60 + fields[2]
                if videoLength.isFinite, videoLength > 0 { return min(container ?? videoLength, videoLength) }
            }
        }
        return container
    }
    var video: Track? { streams.first { $0.codec_type == "video" } }
}

struct MKVSection: Sendable {
    let directory: URL
    var url: URL { directory.appendingPathComponent("section.mp4") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Matroska and “unplayable but valid” MP4/MOV/M4V preparation via bundled `ffmpeg`/`ffprobe`.
///
/// Video is stream-copied (H.264 or HEVC only); audio preserves multichannel surround (up to 5.1/7.1 AAC) for Apple's pipeline.
/// AV1, VP9, and other codecs are out of scope for this bridge.
enum MKVBridge {
    static func requiresBridge(_ source: URL) -> Bool {
        let ext = source.pathExtension.lowercased()
        return ["mkv", "m2ts", "ts", "mts", "vob", "ac4"].contains(ext)
    }
    static func needsPreparation(_ source: URL, asset: AVURLAsset? = nil) async -> Bool {
        if requiresBridge(source) { return true }
        guard ["mp4", "m4v", "mov"].contains(source.pathExtension.lowercased()) else { return false }
        // HEVC tagged hev1 is a common example of a valid video Apple won't open directly.
        return (try? await (asset ?? AVURLAsset(url: source)).load(.isPlayable)) != true
    }
    static func inspect(_ source: URL) async throws -> MKVMetadata {
        let access = FileAccess(source)
        defer { withExtendedLifetime(access) {} }
        let data = try await MediaToolRunner.run("ffprobe", arguments: ["-v", "error", "-protocol_whitelist", "file,pipe,fd", "-show_entries", "format=duration:stream=index,codec_name,codec_type,channels,channel_layout,width,height:stream_tags=language,title,DURATION", "-of", "json", "-i", "fd:"], input: source)
        let result = try JSONDecoder().decode(MKVMetadata.self, from: data)
        let vCodec = result.video?.codec_name ?? ""
        let supportedVideo = vCodec == "hevc" || vCodec == "h264" || (vCodec == "av1" && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
        guard let duration = result.duration, duration.isFinite, duration > 0, duration <= 172_800,
              let video = result.video, supportedVideo,
              let width = video.width, let height = video.height, width > 0, height > 0, width <= 8192, height <= 8192,
              result.streams.count <= 128 else {
            throw StreamFailure(message: "Automatic preparation currently requires H.264, HEVC, or hardware-supported AV1 video, a finite duration, and dimensions up to 8192 pixels. This file is outside those limits.")
        }
        return result
    }
    static let supportedAudioCodecs: Set<String> = ["aac", "aac_latm", "ac3", "eac3", "mp3", "mp3float", "flac", "opus", "vorbis", "pcm_s16le", "pcm_s24le", "pcm_s24be", "dca", "dts", "truehd"]
    static let supportedSubtitleCodecs: Set<String> = ["subrip", "mov_text", "ass", "ssa"]
    static func tracks(_ metadata: MKVMetadata, source: URL, external: SubtitleDocument?) async throws -> StreamTracks {
        var result = StreamTracks()
        for (index, track) in metadata.streams.filter({ $0.codec_type == "audio" }).prefix(32).enumerated() {
            if let codec = track.codec_name, !supportedAudioCodecs.contains(codec) {
                result.notices.append("Audio track \(index + 1) uses an unsupported format (\(codec)) and is unavailable.")
                continue
            }
            let language = track.tags?["language"] ?? "und"
            let label = track.tags?["title"] ?? Locale.current.localizedString(forIdentifier: language) ?? "Audio"
            let rawChannels = track.channels ?? 2
            let channels = rawChannels >= 8 ? 8 : (rawChannels >= 6 ? 6 : 2)
            result.audio.append(StreamAudioTrack(index: index, name: "\(label) · \(index + 1)", language: language, channels: channels, described: false))
        }
        for track in metadata.streams.filter({ $0.codec_type == "subtitle" }).prefix(32) {
            guard supportedSubtitleCodecs.contains(track.codec_name ?? "") else {
                result.notices.append("An embedded MKV subtitle format is unavailable. Load an external SRT instead."); continue
            }
            do {
                let data = try await MediaToolRunner.run("ffmpeg", arguments: ["-v", "error", "-nostdin", "-protocol_whitelist", "file,pipe,fd", "-i", "fd:", "-map", "0:\(track.index)", "-f", "srt", "pipe:1"], input: source)
                guard let text = String(data: data, encoding: .utf8) else { throw MediaIssue.unsupported }
                let doc = try SubtitleDocument.parse(text)
                let language = track.tags?["language"] ?? "und"
                result.subtitles.append(StreamSubtitleTrack(name: "\(Locale.current.localizedString(forIdentifier: language) ?? "Subtitles") · \(track.index)", language: language, document: doc, accessibility: false, forced: false))
            } catch is CancellationError { throw CancellationError() }
            catch { result.notices.append("An embedded MKV subtitle track could not be read. Load an external SRT instead.") }
        }
        if let external { result.subtitles.append(StreamSubtitleTrack(name: "External SRT", language: "und", document: external, accessibility: false, forced: false)) }
        return result
    }
    static func section(source: URL, start: Double, length: Double, videoCodec: String? = nil, audioIndex: Int? = 0) async throws -> MKVSection {
        guard start.isFinite, start >= 0, length.isFinite, length > 0, length <= 6.1 else { throw MediaIssue.unsupported }
        let access = FileAccess(source)
        defer { withExtendedLifetime(access) {} }
        let codec: String?
        if let videoCodec { codec = videoCodec } else { codec = try await inspect(source).video?.codec_name }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirPlayr-MKV-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let section = MKVSection(directory: directory)
        do {
            func decimal(_ value: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) }
            // Copy HEVC/H.264 without re-encoding; retain multichannel surround (AAC 48kHz) for Apple's player.
            // Edit lists retain keyframe preroll while presenting requested source time as local zero.
            var arguments = ["-v", "error", "-nostdin", "-protocol_whitelist", "file,pipe,fd", "-ss", decimal(start), "-i", "fd:", "-t", decimal(length + 0.15)]
            if let codec {
                arguments += ["-map", "0:v:0"]
                if codec == "mpeg2video" {
                    arguments += ["-sn", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-crf", "18", "-tag:v", "avc1"]
                } else {
                    let vTag = codec == "hevc" ? "hvc1" : (codec == "av1" ? "av01" : "avc1")
                    arguments += ["-sn", "-c:v", "copy", "-tag:v", vTag]
                }
            } else {
                arguments += ["-vn"]
            }
            if let audioIndex {
                arguments += ["-map", "0:a:\(audioIndex)?", "-c:a", "aac", "-ar", "48000"]
            } else {
                arguments += ["-an"]
            }
            arguments += ["-fs", "268435456", "-movflags", "+faststart", "-f", "mp4", section.url.path]
            _ = try await MediaToolRunner.run("ffmpeg", arguments: arguments, input: source)
            try Task.checkCancellation()
            return section
        } catch { section.remove(); throw error }
    }
}
