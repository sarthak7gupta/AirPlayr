import XCTest
import AVFoundation
import AVKit
@testable import AirPlayr

@MainActor final class StreamingTests: XCTestCase {
    func testVODPlaylistHasCompleteImmutableTimeline() throws {
        let playlist = try VODPlaylist(duration: 14.25, start: 8)
        XCTAssertEqual(playlist.count, 3)
        let text = String(decoding: playlist.media, as: UTF8.self)
        XCTAssertTrue(text.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(text.contains("#EXT-X-ENDLIST"))
        XCTAssertTrue(text.contains("#EXTINF:2.250000,"))
        XCTAssertEqual(text.components(separatedBy: "#EXT-X-DISCONTINUITY").count - 1, 2)
        XCTAssertFalse(text.contains("PROGRAM-DATE-TIME"))
        XCTAssertEqual(playlist.media, playlist.media)
        XCTAssertThrowsError(try VODPlaylist(duration: .infinity, start: 0))
        XCTAssertThrowsError(try VODPlaylist(duration: 0, start: 0))
    }
    func testFixtureRemoteStyleForwardBackwardSeeks() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Big Buck Bunny 1080p_h264", withExtension: "mp4"))
        let session = AutomaticStreamSession(source: source, start: 5, subtitles: nil)
        defer { session.stop() }
        let began = Date()
        let url = try await session.prepare(host: "127.0.0.1", onFailure: { _ in })
        let store = try XCTUnwrap(session.store)
        let initialCount = await store.cachedSegmentCount
        XCTAssertEqual(initialCount, 1, "Starting at 5 seconds must not encode the preceding movie")
        print("VOD INITIAL PREPARATION", Date().timeIntervalSince(began))
        let originalManifest = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("media.m3u8")).0
        let originalDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = false; player.automaticallyWaitsToMinimizeStalling = true
        player.currentItem?.preferredForwardBufferDuration = 6
        let window = videoWindow(player)
        defer { player.pause(); player.replaceCurrentItem(with: nil); window.close() }
        try await waitUntil { player.currentItem?.status == .readyToPlay || player.currentItem?.status == .failed }
        XCTAssertNil(player.currentItem?.error)
        XCTAssertEqual(player.currentItem?.duration.seconds ?? 0, originalDuration, accuracy: 0.05)
        let item = player.currentItem
        // Seek through AVPlayer itself, like a remote receiver. No app restart or playlist replacement.
        for target in [5.0, 3.0, 8.0, 1.2, 5.8, originalDuration - 1.0] {
            player.pause()
            let began = Date()
            try await seek(player, to: target)
            print("VOD SEEK", target, Date().timeIntervalSince(began))
            XCTAssertTrue(player.currentItem === item)
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(player.currentTime().seconds, target, accuracy: 0.2)
            player.playImmediately(atRate: 1)
            let advance = target == 5.8 ? 1.5 : 0.4
            try await waitUntil { player.currentTime().seconds > target + advance || player.currentItem?.status == .failed }
            XCTAssertNil(player.currentItem?.error)
            if player.currentTime().seconds <= target + advance - 0.1 {
                print("VOD STALL", player.rate, player.timeControlStatus.rawValue, player.reasonForWaitingToPlay as Any, player.currentItem?.loadedTimeRanges as Any, player.currentItem?.errorLog()?.events.map { $0.errorComment ?? "?" } as Any)
            }
            XCTAssertGreaterThan(player.currentTime().seconds, target + advance - 0.1)
        }
        let afterManifest = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("media.m3u8")).0
        XCTAssertEqual(afterManifest, originalManifest, "VOD playlist must not change as sections are prepared")
    }
    func testOnDemandCoalescingImmutableBytesAndCleanup() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Big Buck Bunny 1080p_h264", withExtension: "mp4"))
        let session = AutomaticStreamSession(source: source, start: 0, subtitles: nil)
        let url = try await session.prepare(host: "127.0.0.1", onFailure: { _ in })
        let store = try XCTUnwrap(session.store)
        let cachedURL = await store.cacheURL
        let directory = try XCTUnwrap(cachedURL)
        let target = url.deletingLastPathComponent().appendingPathComponent("s1.m4s")
        async let first = URLSession.shared.data(from: target)
        async let second = URLSession.shared.data(from: target)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.0, b.0)
        XCTAssertEqual((a.1 as? HTTPURLResponse)?.statusCode, 200)
        let count = await store.cachedSegmentCount
        XCTAssertEqual(count, 2, "Only startup and the requested distant section should exist")
        let repeated = try await URLSession.shared.data(from: target)
        XCTAssertEqual(a.0, repeated.0)
        session.stop()
        try await waitUntil { !FileManager.default.fileExists(atPath: directory.path) }
    }
    func testPlayerServiceStreamingPausedSeekAndCleanup() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let service = PlaybackService(library: LibraryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false
        let window = videoWindow(service.player)
        defer { window.close() }
        service.open(source)
        try await waitUntil { service.player.currentItem?.status == .readyToPlay }
        service.prepareForTV()
        try await waitUntil { !service.isPreparingForTV && service.phase != .seeking && service.player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(service.isCompatibilityStreaming)
        service.seek(to: 2)
        try await waitUntil { service.phase != .seeking }
        XCTAssertEqual(service.position, 2, accuracy: 0.2)
        XCTAssertEqual(service.player.rate, 0)
        service.togglePlayback()
        try await waitUntil { service.position > 2.4 }
        service.stop()
        XCTAssertNil(service.player.currentItem)
        XCTAssertFalse(service.isCompatibilityStreaming)
        XCTAssertEqual(service.phase, .empty)
    }
    func testSubtitleTimingInDistantSection() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let asset = AVURLAsset(url: fixture)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let composition = AVMutableComposition()
        let target = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        for n in 0..<3 { try target.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)), of: track, at: CMTime(seconds: Double(n)*5, preferredTimescale: 600)) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: source) }
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        exporter.outputURL = source
        exporter.outputFileType = .mov
        await exporter.export()
        guard exporter.status == .completed else { throw exporter.error ?? NSError(domain: "AirPlayrTests", code: 1) }
        let doc = try SubtitleDocument.parse("1\n00:00:07,000 --> 00:00:09,000\nDISTANT SUBTITLE")
        let session = AutomaticStreamSession(source: source, start: 7, subtitles: doc, burnSubtitles: true)
        defer { session.stop() }
        let url = try await session.prepare(host: "127.0.0.1", onFailure: { _ in }).deletingLastPathComponent()
        var combined = try await URLSession.shared.data(from: url.appendingPathComponent("i1.mp4")).0
        combined.append(try await URLSession.shared.data(from: url.appendingPathComponent("s1.m4s")).0)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try combined.write(to: output)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let before = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let during = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        let after = try await generator.image(at: CMTime(seconds: 3.5, preferredTimescale: 600)).image
        XCTAssertLessThan(whitePixels(before), 50)
        XCTAssertGreaterThan(whitePixels(during), 100)
        XCTAssertLessThan(whitePixels(after), 50)
    }
    func testRanges() {
        XCTAssertEqual(StreamHTTPServer.byteRange("Range: bytes=2-4", count: 10), 2..<5)
        XCTAssertEqual(StreamHTTPServer.byteRange("Range: bytes=-3", count: 10), 7..<10)
        XCTAssertEqual(StreamHTTPServer.byteRange("Range: bytes=4-", count: 10), 4..<10)
        XCTAssertNil(StreamHTTPServer.byteRange("Range: bytes=10-", count: 10))
        XCTAssertNil(StreamHTTPServer.byteRange("Range: bytes=0-1,4-5", count: 10))
    }
    func testRealHTTPPlaybackAndSubtitlePixels() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let doc = try SubtitleDocument.parse("1\n00:00:01,000 --> 00:00:03,000\nSTREAMING SUBTITLE")
        let session = AutomaticStreamSession(source: source, start: 2, subtitles: doc, burnSubtitles: true)
        defer { session.stop() }
        let url = try await session.prepare(host: "127.0.0.1", onFailure: { _ in })
        let root = url.deletingLastPathComponent()
        let (manifest, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: manifest, as: UTF8.self).contains("#EXT-X-STREAM-INF"))
        let (_, denied) = try await URLSession.shared.data(from: root.deletingLastPathComponent().appendingPathComponent("index.m3u8"))
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
        let (_, absent) = try await URLSession.shared.data(from: root.appendingPathComponent("s999999.m4s"))
        XCTAssertEqual((absent as? HTTPURLResponse)?.statusCode, 404)
        var request = URLRequest(url: root.appendingPathComponent("i0.mp4"))
        request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        let (range, partial) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((partial as? HTTPURLResponse)?.statusCode, 206); XCTAssertEqual(range.count, 16)
        var combined = try await URLSession.shared.data(from: root.appendingPathComponent("i0.mp4")).0
        combined.append(try await URLSession.shared.data(from: root.appendingPathComponent("s0.m4s")).0)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try combined.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        let before = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let during = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        XCTAssertLessThan(whitePixels(before), 50)
        XCTAssertGreaterThan(whitePixels(during), 100)
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = false; player.automaticallyWaitsToMinimizeStalling = true
        let window = videoWindow(player)
        defer { player.pause(); player.replaceCurrentItem(with: nil); window.close() }
        try await waitUntil { player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(player.currentItem?.duration.seconds ?? 0, 5, accuracy: 0.05)
        try await seek(player, to: 2)
        player.playImmediately(atRate: 1)
        try await waitUntil { player.currentTime().seconds > 2.5 }
        player.pause()
        try await seek(player, to: 1)
        XCTAssertEqual(player.currentTime().seconds, 1, accuracy: 0.2)
    }
    private func videoWindow(_ player: AVPlayer) -> NSWindow {
        let view = AVPlayerView(frame: CGRect(x: 0, y: 0, width: 640, height: 360)); view.controlsStyle = .none; view.player = player
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        return window
    }
    @MainActor private final class SeekCompletion { var value: Bool? }
    private func seek(_ player: AVPlayer, to seconds: Double) async throws {
        let completion = SeekCompletion()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { result in Task { @MainActor in completion.value = result } }
        try await waitUntil { completion.value != nil }
        XCTAssertEqual(completion.value, true)
    }
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(predicate(), "Timed out waiting for movie playback", file: file, line: line)
    }
    private func whitePixels(_ image: CGImage) -> Int {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 220 && bytes[$0+1] > 220 && bytes[$0+2] > 220 }.count
    }
}
