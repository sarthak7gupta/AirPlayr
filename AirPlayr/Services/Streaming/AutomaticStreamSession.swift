import AVFoundation
import UniformTypeIdentifiers

/// One TV compatibility session: inspect tracks, start `VODStreamStore`, and serve HLS over HTTP.
@MainActor final class AutomaticStreamSession {
    private let source: URL
    private let start: Double
    private let appearance: SubtitleAppearance
    private let subtitles: SubtitleDocument?
    private let burnSubtitles: Bool
    private(set) var trackNotices: [String] = []
    private let access: FileAccess
    private var server: StreamHTTPServer?
    private(set) var store: VODStreamStore?
    private(set) var url: URL?
    private var stopped = false

    init(source: URL, start: Double, subtitles: SubtitleDocument?, appearance: SubtitleAppearance = SubtitleAppearance(), burnSubtitles: Bool = false) {
        self.burnSubtitles = burnSubtitles
        self.source = source; self.start = max(0, start); self.subtitles = subtitles; self.appearance = appearance
        access = FileAccess(source)
    }
    func prepare(host: String? = nil, onFailure: @escaping @Sendable (String) -> Void) async throws -> URL {
        do {
            let needsPreparation = await MKVBridge.needsPreparation(source)
            let mkv = needsPreparation ? try await MKVBridge.inspect(source) : nil
            let duration: Double
            if let mkv, let length = mkv.duration { duration = length }
            else { duration = try await AVURLAsset(url: source).load(.duration).seconds }
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            let playlist = try VODPlaylist(duration: duration, start: start)
            let source = self.source, external = burnSubtitles ? nil : subtitles
            let inspection = Task.detached(priority: .userInitiated) {
                if let mkv { return try await MKVBridge.tracks(mkv, source: source, external: external) }
                return try await StreamTracks.inspect(source: source, external: external)
            }
            let tracks = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            trackNotices = tracks.notices
            let store = try VODStreamStore(source: source, playlist: playlist, subtitles: burnSubtitles ? subtitles : nil, appearance: appearance, tracks: tracks, preparedCodec: mkv?.video?.codec_name, needsPreparation: needsPreparation, onFailure: onFailure)
            self.store = store
            try await store.prepare()
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            let server = StreamHTTPServer { name in try await store.resource(name) }
            self.server = server
            let url = try await server.start(host: host)
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            self.url = url
            return url
        } catch {
            stop()
            throw error
        }
    }
    func stop() {
        stopped = true; server?.stop(); server = nil; url = nil
        if let store { store.closeCache(); Task { await store.stop() } }; store = nil
    }
    deinit {
        server?.stop()
        if let store { store.closeCache(); Task { await store.stop() } }
    }
}

/// Uses Apple's segment-producing encoder. Samples are read and encoded off the main actor.
enum IncrementalEncoder {
    struct Pump: @unchecked Sendable {
        let run: () async throws -> Void
    }
    static func encode(source: URL, start: Double, end: Double? = nil, subtitles: SubtitleDocument?, appearance: SubtitleAppearance, buffer: HLSBuffer, audioOnly: Int? = nil, timestampOffset: Double = 0, allowPreparation: Bool = true, needsPreparation: Bool? = nil, preparedCodec: String? = nil) async throws {
        let shouldPrepare: Bool
        if !allowPreparation { shouldPrepare = false }
        else if let needsPreparation { shouldPrepare = needsPreparation }
        else { shouldPrepare = await MKVBridge.needsPreparation(source) }
        if shouldPrepare {
            guard let end else { throw MediaIssue.unsupported }
            let section = try await MKVBridge.section(source: source, start: start, length: end - start, videoCodec: preparedCodec, audioIndex: audioOnly ?? 0)
            defer { section.remove() }
            let shifted = subtitles.map { doc in
                SubtitleDocument(cues: doc.cues.filter { $0.end > start && $0.start < end }.map { SubtitleCue(start: $0.start - start, end: $0.end - start, text: $0.text) })
            }
            try await encode(source: section.url, start: 0, end: end - start, subtitles: shifted, appearance: appearance, buffer: buffer, audioOnly: audioOnly == nil ? nil : 0, timestampOffset: start, allowPreparation: false)
            return
        }
        let access = FileAccess(source)
        defer { withExtendedLifetime(access) {} }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, start < duration.seconds,
              let video = try await asset.loadTracks(withMediaType: .video).first else { throw MediaIssue.unsupported }
        let size = try await video.load(.naturalSize)
        let preferred = try await video.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(preferred)
        guard rect.width > 0, rect.height > 0 else { throw MediaIssue.unsupported }
        let startTime = CMTime(seconds: start, preferredTimescale: 600)
        let endTime = CMTime(seconds: min(duration.seconds, end ?? duration.seconds), preferredTimescale: 600)
        guard endTime > startTime else { throw MediaIssue.unsupported }
        let offset = CMTime(seconds: timestampOffset, preferredTimescale: 600)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioIndex = audioOnly ?? 0
        let passthroughEnabled = (UserDefaults.standard.object(forKey: "zeroReencodePassthroughEnabled") as? Bool) ?? true
        if passthroughEnabled, subtitles == nil, audioOnly == nil, preferred == .identity,
           await tryPassthroughEncode(asset: asset, video: video, audioTracks: audioTracks, audioIndex: audioIndex, startTime: startTime, endTime: endTime, offset: offset, buffer: buffer) {
            return
        }
        buffer.reset()
        let maxWidth: CGFloat = subtitles == nil ? 3840 : 1280
        let maxHeight: CGFloat = subtitles == nil ? 2160 : 720
        let scale = min(1, min(maxWidth/rect.width, maxHeight/rect.height))
        let render = CGSize(width: max(2, floor(rect.width*scale/2)*2), height: max(2, floor(rect.height*scale/2)*2))
        let transform = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)).concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let instruction = SubtitleVideoInstruction(trackID: video.trackID, transform: transform, duration: duration, subtitles: subtitles, appearance: appearance)
        let videoComposition = legacyComposition(instruction: instruction, size: render)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: startTime, duration: endTime-startTime)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.initialSegmentStartTime = startTime + offset
        writer.delegate = buffer
        let bitRate = render.width > 1920 ? 12_000_000 : (render.width > 1280 ? 6_500_000 : 3_500_000)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(render.width), AVVideoHeightKey: Int(render.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate, AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel, AVVideoMaxKeyFrameIntervalKey: 60, AVVideoMaxKeyFrameIntervalDurationKey: 2, AVVideoAllowFrameReorderingKey: false]
        ])
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = audioOnly == nil ? [(videoOutput, videoInput)] : []
        if audioTracks.indices.contains(audioIndex) {
            let audio = audioTracks[audioIndex]
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160000])
            pairs.append((output, input))
        }
        let pumps = try legacyPumps(reader: reader, writer: writer, pairs: pairs, buffer: buffer, offset: offset)
        writer.startSession(atSourceTime: startTime + offset)
        let lifetime = WriterLifetime(reader: reader, writer: writer)
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            lifetime.cancel()
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for pump in pumps { group.addTask { try await pump.run() } }
                    try await group.waitForAll()
                }
                try Task.checkCancellation()
                try await lifetime.finish(at: endTime + offset)
                if let error = writer.error { throw error }
                if let error = reader.error { throw error }
                guard writer.status == .completed else { throw StreamFailure(message: "Preparing this movie section timed out or was cancelled. Try again or reopen the file.") }
            } catch {
                lifetime.cancel()
                if error is CancellationError, !Task.isCancelled {
                    throw StreamFailure(message: "Preparing this movie section stopped unexpectedly. Try again or reopen the file.")
                }
                throw error
            }
        } onCancel: { lifetime.cancelWriter() }
    }
    /// Serialize cancellation with the synchronous start of finalization. A cancelled writer must
    /// never receive finishWriting (AVFoundation raises an Objective-C exception in that case).
    /// Do not call `reader.cancelReading()` from the asynchronous `onCancel` handler while a pump
    /// task may be inside `copyNextSampleBuffer()`, as `FigAssetReader` tears down its pixel transfer
    /// session unsafely if called concurrently with sample reading.
    private final class WriterLifetime: @unchecked Sendable {
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let lock = NSLock()
        private var cancelled = false
        init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }
        func cancelWriter() {
            lock.withLock {
                cancelled = true
                if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
            }
        }
        func cancel() {
            lock.withLock {
                cancelled = true
                if reader.status == .reading { reader.cancelReading() }
                if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
            }
        }
        func finish(at time: CMTime) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    guard !cancelled, writer.status == .writing else { continuation.resume(throwing: writer.error ?? CancellationError()); return }
                    writer.endSession(atSourceTime: time)
                    writer.finishWriting {
                        if self.writer.status == .completed { continuation.resume() }
                        else { continuation.resume(throwing: self.writer.error ?? CancellationError()) }
                    }
                }
            }
        }
    }
    private static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
    private static func tryPassthroughEncode(asset: AVURLAsset, video: AVAssetTrack, audioTracks: [AVAssetTrack], audioIndex: Int, startTime: CMTime, endTime: CMTime, offset: CMTime, buffer: HLSBuffer) async -> Bool {
        return false
    }
    private static func shiftedSample(_ sample: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        guard offset != .zero else { return sample }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0, count <= 4096 else { throw MediaIssue.unsupported }
        var timings = Array(repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else { throw MediaIssue.unsupported }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid { timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + offset }
            if timings[index].decodeTimeStamp.isValid { timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + offset }
        }
        var shifted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &shifted) == noErr,
              let shifted else { throw MediaIssue.unsupported }
        return shifted
    }
    private static func throttle(_ buffer: HLSBuffer) async throws {
        try Task.checkCancellation()
        if let error = buffer.error { throw StreamFailure(message: error) }
    }
    private static func legacyComposition(instruction: SubtitleVideoInstruction, size: CGSize) -> AVVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = SubtitleVideoCompositor.self
        composition.frameDuration = CMTime(value: 1, timescale: 30); composition.renderSize = size; composition.instructions = [instruction]
        return composition
    }
    private static func legacyPumps(reader: AVAssetReader, writer: AVAssetWriter, pairs: [(AVAssetReaderOutput, AVAssetWriterInput)], buffer: HLSBuffer, offset: CMTime) throws -> [Pump] {
        var pumps: [Pump] = []
        for (output, input) in pairs {
            guard reader.canAdd(output), writer.canAdd(input) else { throw MediaIssue.unsupported }
            reader.add(output); writer.add(input)
            pumps.append(Pump {
                while !Task.isCancelled, let sample = output.copyNextSampleBuffer() {
                    try await throttle(buffer)
                    while !input.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 5_000_000) }
                    guard input.append(try shiftedSample(sample, by: offset)) else { throw writer.error ?? MediaIssue.unsupported }
                }
                try Task.checkCancellation()
                input.markAsFinished()
            })
        }
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? MediaIssue.unsupported }
        return pumps
    }
}
