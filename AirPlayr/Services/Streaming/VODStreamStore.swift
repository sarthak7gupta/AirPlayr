import AVFoundation

/// A fixed movie timeline. Every URI can be produced independently, even before earlier sections.
struct VODPlaylist: Sendable {
    static let segmentDuration = 6.0
    let duration: Double
    let start: Double
    var count: Int { Int(ceil(duration / Self.segmentDuration)) }
    init(duration: Double, start: Double) throws {
        guard duration.isFinite, duration > 0, duration <= 172_800, start.isFinite else {
            throw StreamFailure(message: "This movie does not have a supported finite duration.")
        }
        self.duration = duration; self.start = min(max(0, start), max(0, duration - 0.1))
    }
    func length(_ index: Int) -> Double { min(Self.segmentDuration, duration - Double(index) * Self.segmentDuration) }
    var media: Data { media(prefix: "") }
    func media(prefix: String) -> Data {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:6", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-INDEPENDENT-SEGMENTS", String(format: "#EXT-X-START:TIME-OFFSET=%.6f,PRECISE=YES", start)]
        for index in 0..<count {
            // Each section has its own decoder initialization and original source timestamps.
            if index > 0 { lines.append("#EXT-X-DISCONTINUITY") }
            lines += ["#EXT-X-MAP:URI=\"\(prefix)i\(index).mp4\"", String(format: "#EXTINF:%.6f,", length(index)), "\(prefix)s\(index).m4s"]
        }
        lines.append("#EXT-X-ENDLIST")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

private final class StreamCacheDirectory: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var closed = false
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("AirPlayr-VOD-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func write(initialization: Data, media: Data, index: Int, prefix: String) throws {
        try lock.withLock {
            guard !closed else { throw CancellationError() }
            try initialization.write(to: url.appendingPathComponent("\(prefix)i\(index).mp4"), options: .atomic)
            try media.write(to: url.appendingPathComponent("\(prefix)s\(index).m4s"), options: .atomic)
        }
    }
    func read(_ name: String) throws -> Data {
        try lock.withLock {
            guard !closed else { throw CancellationError() }
            return try Data(contentsOf: url.appendingPathComponent(name), options: .mappedIfSafe)
        }
    }
    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? FileManager.default.removeItem(at: url)
        }
    }
    deinit { close() }
}

enum TemporaryCacheCleanup {
    static let prefixes = ["AirPlayr-VOD-", "AirPlayr-MKV-", "AirPlayr-Export-"]
    static func removeAbandonedCaches(in directory: URL = FileManager.default.temporaryDirectory) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for item in items where prefixes.contains(where: { item.lastPathComponent.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: item)
        }
    }
}

/// Disk-backed immutable sections, encoded only on request. Serial jobs bound encoder memory.
actor VODStreamStore {
    let playlist: VODPlaylist
    private let source: URL
    private let subtitles: SubtitleDocument?
    private let appearance: SubtitleAppearance
    nonisolated private let cache: StreamCacheDirectory
    private var pending: [String: Task<Void, Error>] = [:]
    private var tail: Task<Void, Never>?
    private var completed: Set<String> = []
    private var stopped = false
    private let tracks: StreamTracks
    private let preparedCodec: String?
    private let needsPreparation: Bool?
    private let onFailure: @Sendable (String) -> Void
    var cachedSegmentCount: Int { completed.count }
    var cacheURL: URL? { stopped ? nil : cache.url }
    nonisolated func closeCache() { cache.close() }

    init(source: URL, playlist: VODPlaylist, subtitles: SubtitleDocument?, appearance: SubtitleAppearance, tracks: StreamTracks = StreamTracks(), preparedCodec: String? = nil, needsPreparation: Bool? = nil, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.source = source; self.playlist = playlist; self.subtitles = subtitles; self.appearance = appearance
        self.tracks = tracks; self.preparedCodec = preparedCodec; self.needsPreparation = needsPreparation
        self.onFailure = onFailure; cache = try StreamCacheDirectory()
    }
    func prepare() async throws {
        try await ensure(Int(playlist.start / VODPlaylist.segmentDuration))
    }
    func resource(_ name: String) async throws -> (Data, String)? {
        guard !stopped else { throw CancellationError() }
        if name == "index.m3u8" { return (tracks.master(), "application/vnd.apple.mpegurl") }
        if name == "media.m3u8" { return (playlist.media, "application/vnd.apple.mpegurl") }
        if name.hasPrefix("t") { return subtitleResource(name) }
        var leaf = name, prefix = "", audio: Int?
        if name.hasPrefix("a") {
            let parts = name.dropFirst().split(separator: "_", maxSplits: 1)
            if name.hasSuffix(".m3u8"), let index = Int(name.dropFirst().dropLast(5)),
               tracks.audio.contains(where: { $0.index == index }), index > 0, name == "a\(index).m3u8" {
                return (playlist.media(prefix: "a\(index)_"), "application/vnd.apple.mpegurl")
            }
            guard parts.count == 2, let index = Int(parts[0]), index > 0,
                  tracks.audio.contains(where: { $0.index == index }), parts[0] == String(index) else { return nil }
            audio = index; prefix = "a\(index)_"; leaf = String(parts[1])
        }
        let initialization = leaf.hasPrefix("i") && leaf.hasSuffix(".mp4")
        guard initialization || (leaf.hasPrefix("s") && leaf.hasSuffix(".m4s")),
              let index = Int(leaf.dropFirst().dropLast(4)), index >= 0, index < playlist.count,
              leaf == (initialization ? "i\(index).mp4" : "s\(index).m4s") else { return nil }
        try await ensure(index, audio: audio)
        guard !stopped else { throw CancellationError() }
        return (try cache.read(prefix + leaf), audio == nil ? "video/mp4" : "audio/mp4")
    }
    private func subtitleResource(_ name: String) -> (Data, String)? {
        if name.hasSuffix(".m3u8"), let track = Int(name.dropFirst().dropLast(5)),
           tracks.subtitles.indices.contains(track), name == "t\(track).m3u8" {
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:6", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0"]
            for index in 0..<playlist.count {
                if index > 0 { lines.append("#EXT-X-DISCONTINUITY") }
                lines += [String(format: "#EXTINF:%.6f,", playlist.length(index)), "t\(track)_\(index).vtt"]
            }
            lines.append("#EXT-X-ENDLIST")
            return (Data((lines.joined(separator: "\n") + "\n").utf8), "application/vnd.apple.mpegurl")
        }
        guard name.hasSuffix(".vtt") else { return nil }
        let parts = name.dropFirst().dropLast(4).split(separator: "_")
        guard parts.count == 2, let track = Int(parts[0]), let index = Int(parts[1]),
              tracks.subtitles.indices.contains(track), index >= 0, index < playlist.count,
              name == "t\(track)_\(index).vtt" else { return nil }
        let start = Double(index) * VODPlaylist.segmentDuration
        return (StreamTracks.webVTT(tracks.subtitles[track].document, start: start, end: start + playlist.length(index)), "text/vtt")
    }
    private func ensure(_ index: Int, audio: Int? = nil) async throws {
        guard !stopped else { throw CancellationError() }
        let prefix = audio.map { "a\($0)_" } ?? ""
        let key = prefix + String(index)
        if completed.contains(key) { return }
        if let task = pending[key] { try await task.value; return }
        // Disconnected HTTP clients must not leave an unbounded backlog of encoder jobs.
        guard pending.count < 24 else { throw StreamFailure(message: "Streaming is busy. Retry this section shortly.") }
        let preceding = tail, source = self.source, subtitles = self.subtitles, appearance = self.appearance, cache = self.cache
        let preparedCodec = self.preparedCodec, needsPreparation = self.needsPreparation
        let begin = Double(index) * VODPlaylist.segmentDuration
        let length = playlist.length(index)
        let task = Task.detached(priority: .userInitiated) {
            await preceding?.value
            try Task.checkCancellation()
            let capacity = try cache.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let capacity, capacity < 100_000_000 { throw StreamFailure(message: "TV streaming needs temporary disk space. Free some space on this Mac and retry.") }
            let buffer = HLSBuffer(timingMediaType: audio == nil ? .video : .audio)
            defer { buffer.stop() }
            try await IncrementalEncoder.encode(source: source, start: begin, end: begin + length, subtitles: subtitles, appearance: appearance, buffer: buffer, audioOnly: audio, needsPreparation: needsPreparation, preparedCodec: preparedCodec)
            if let error = buffer.error { throw StreamFailure(message: error) }
            // AAC reports include encoder priming/padding (up to several 1024-sample packets).
            // The playlist and writer session still use the exact original section boundaries.
            let timingTolerance = audio == nil ? 1.0 / 30 + 0.005 : 0.08
            if abs(buffer.bufferedDuration - length) > timingTolerance {
                NSLog("Movie section timing mismatch: start %.6f expected %.6f actual %.6f", begin, length, buffer.bufferedDuration)
            }
            guard abs(buffer.bufferedDuration - length) <= timingTolerance,
                  let initialization = buffer.resource("init.mp4")?.0 else {
                throw StreamFailure(message: "The encoder could not produce accurate movie timing for TV seeking.")
            }
            var media = Data()
            for number in 0..<buffer.segmentCount {
                guard let data = buffer.resource("s\(number).m4s")?.0 else { throw MediaIssue.unsupported }
                media.append(data)
            }
            try Task.checkCancellation()
            try cache.write(initialization: initialization, media: media, index: index, prefix: prefix)
        }
        pending[key] = task
        tail = Task { _ = try? await task.value }
        do {
            try await task.value
            guard !stopped else { throw CancellationError() }
            completed.insert(key); pending[key] = nil
        } catch {
            pending[key] = nil
            if !(error is CancellationError), !stopped {
                let message = (error as? StreamFailure)?.message ?? "Could not prepare this section for your TV. \(PlaybackDiagnostics.code(error))"
                onFailure(message)
            }
            throw error
        }
    }
    func stop() async {
        stopped = true
        let tasks = Array(pending.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.result }
        pending.removeAll(); completed.removeAll(); tail = nil; cache.close()
    }
}
