import Foundation

// MARK: - Library and playback policy

/// A recent item persisted as a read-only security-scoped bookmark plus resume position.
struct MediaEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var bookmark: Data
    var lastOpened = Date()
    var position: Double = 0
    var duration: Double?
}

enum MediaIssue: LocalizedError, Equatable {
    case unreadable, unsupported, subtitles(String), persistence
    var errorDescription: String? {
        switch self {
        case .unreadable: return "This file is missing or inaccessible. Open it again to grant access."
        case .unsupported: return "Apple’s media engine cannot play this file. Try an MP4 with H.264 video and AAC audio. MKV files with H.264/HEVC video are prepared automatically; other containers or codecs may be unsupported."
        case .subtitles(let reason): return "Subtitles could not be loaded. \(reason)"
        case .persistence: return "The library could not be saved. Check available disk space and folder permissions."
        }
    }
}

enum PlaybackPhase: String {
    case empty = "Open a movie to begin"
    case loading = "Loading", ready = "Ready", playing = "Playing", paused = "Paused"
    case seeking = "Seeking", waiting = "Buffering", ended = "Finished", failed = "Playback failed"
}

/// File-extension allow list and shared time/seek helpers. Extensions are picker hints only.
enum MediaPolicy {
    // A picker hint, never a guarantee of codec compatibility.
    #if os(iOS)
    static let extensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "m4a", "mp3", "aac", "wav", "flac"]
    #else
    static let extensions: Set<String> = ["mkv", "mp4", "mov", "m4v", "m2ts", "ts", "mts", "m3u8", "ac4", "vob", "iso", "m4a", "mp3", "aac", "wav", "aif", "aiff", "caf", "flac"]
    #endif
    static func validate(_ url: URL) throws {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw MediaIssue.unreadable }
        guard extensions.contains(url.pathExtension.lowercased()) else { throw MediaIssue.unsupported }
    }
    static func seekTarget(_ seconds: Double, duration: Double) -> Double? {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(max(seconds, 0), duration)
    }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—:—" }
        let value = Int(min(seconds, 3_600_000))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}
