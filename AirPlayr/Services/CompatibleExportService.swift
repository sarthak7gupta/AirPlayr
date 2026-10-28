import AVFoundation
import AppKit
import Observation

/// User-initiated offline transcode to a standalone H.264/AAC MP4 (up to 720p/30 SDR).
@MainActor @Observable final class CompatibleExportService {
    private(set) var isExporting = false
    private(set) var output: URL?
    var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(source: URL, destination: URL, subtitles: SubtitleDocument?, appearance: SubtitleAppearance = SubtitleAppearance()) {
        guard !isExporting else { return }
        isExporting = true; output = nil
        message = "Converting to H.264/AAC, up to 720p at 30 fps. This may take several minutes."
        task = Task {
            do {
                try await Self.export(source: source, destination: destination, subtitles: subtitles, appearance: appearance)
                output = destination
                message = "Compatible copy saved. Open it and select your TV. Receiver compatibility still depends on the device."
            } catch is CancellationError { message = "Export cancelled. Your original is unchanged." }
            catch { message = "Export failed: \(error.localizedDescription)" }
            isExporting = false
        }
    }
    func cancel() { task?.cancel() }

    static func export(source: URL, destination: URL, subtitles: SubtitleDocument?, appearance: SubtitleAppearance = SubtitleAppearance()) async throws {
        let sourceAccess = FileAccess(source)
        let destinationAccess = FileAccess(destination)
        defer { withExtendedLifetime((sourceAccess, destinationAccess)) {} }
        guard source.standardizedFileURL != destination.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExportIssue("Choose a new filename. Export never replaces existing files.")
        }
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportIssue("No decodable video track was found.") }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw ExportIssue("The movie has no finite duration.") }
        let size = try await video.load(.naturalSize)
        let preferred = try await video.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(preferred)
        guard rect.width > 0, rect.height > 0 else { throw ExportIssue("The video dimensions are invalid.") }
        let scale = min(1, min(1280 / rect.width, 720 / rect.height))
        let render = CGSize(width: max(2, floor(rect.width * scale / 2) * 2), height: max(2, floor(rect.height * scale / 2) * 2))
        let transform = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)).concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ExportIssue("Could not prepare a video track.") }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioRange = try await audio.load(.timeRange)
            let range = CMTimeRangeGetIntersection(audioRange, otherRange: CMTimeRange(start: .zero, duration: duration))
            if range.duration.seconds > 0 { try audioTrack.insertTimeRange(range, of: audio, at: range.start) }
        }
        let instruction = SubtitleVideoInstruction(trackID: videoTrack.trackID, transform: transform, duration: duration, subtitles: subtitles, appearance: appearance)
        let videoComposition = makeVideoComposition(instruction: instruction, size: render)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720), session.supportedFileTypes.contains(.mp4) else { throw ExportIssue("Apple’s exporter cannot convert this media to MP4.") }
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true
        try Task.checkCancellation()
        // Export only into our own directory. A destination created concurrently is never deleted.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("AirPlayr-Export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedOutput = staging.appendingPathComponent("movie.mp4")
        do {
            try await runExportSession(session, to: stagedOutput)
            try Task.checkCancellation()
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: stagedOutput, to: destination)
            }.value
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ExportIssue("Apple’s encoder could not finish. Check disk space and choose a writable destination. \(PlaybackDiagnostics.code(error))")
        }
    }

    private static func makeVideoComposition(instruction: SubtitleVideoInstruction, size: CGSize) -> AVVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = SubtitleVideoCompositor.self
        composition.frameDuration = CMTime(value: 1, timescale: 30); composition.renderSize = size; composition.instructions = [instruction]
        return composition
    }
    private static func runExportSession(_ session: AVAssetExportSession, to url: URL) async throws {
        session.outputURL = url; session.outputFileType = .mp4
        await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
        guard session.status == .completed else { throw session.error ?? ExportIssue("Export did not complete.") }
    }
}

struct ExportIssue: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}
