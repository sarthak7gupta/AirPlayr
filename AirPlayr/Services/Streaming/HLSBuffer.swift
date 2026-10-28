import Foundation
import AVFoundation

struct StreamFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One short encoder job, never a live playlist. Cleared after its bytes reach the session cache.
final class HLSBuffer: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var initialization: Data?
    private var fragments: [Data] = []
    private var total = 0.0
    private var failure: String?
    private var bytes = 0
    private var stopped = false
    private let timingMediaType: AVMediaType
    init(timingMediaType: AVMediaType = .video) { self.timingMediaType = timingMediaType; super.init() }
    private let memoryLimit = 160 * 1024 * 1024

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.withLock {
            guard !stopped, failure == nil else { return }
            bytes += data.count
            guard bytes <= memoryLimit else { failure = "The encoder section exceeded its memory limit."; return }
            if segmentType == .initialization { initialization = data; return }
            if let report = segmentReport?.trackReports.first(where: { $0.mediaType == timingMediaType }) {
                if report.duration.seconds.isFinite, report.duration.seconds > 0 {
                    total += report.duration.seconds
                } else if report.firstVideoSampleInformation != nil {
                    failure = "The encoder did not produce valid section timing."; return
                }
            }
            // AAC can flush an audio-only fragment with an empty/invalid-duration video report.
            // The caller validates the total video duration once the section is complete.
            fragments.append(data)
        }
    }
    var error: String? { lock.withLock { failure } }
    var bufferedDuration: Double { lock.withLock { total } }
    var segmentCount: Int { lock.withLock { fragments.count } }
    func reset() {
        lock.withLock {
            guard !stopped else { return }
            initialization = nil; fragments.removeAll(); total = 0.0; failure = nil; bytes = 0
        }
    }
    func stop() { lock.withLock { stopped = true; initialization = nil; fragments.removeAll(); bytes = 0 } }
    func resource(_ name: String) -> (Data, String)? {
        lock.withLock {
            guard !stopped else { return nil }
            if name == "init.mp4", let initialization { return (initialization, "video/mp4") }
            guard name.hasPrefix("s"), name.hasSuffix(".m4s"), let index = Int(name.dropFirst().dropLast(4)), fragments.indices.contains(index) else { return nil }
            return (fragments[index], "video/mp4")
        }
    }
}
