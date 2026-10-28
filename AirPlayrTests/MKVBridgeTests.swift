import XCTest
import AVFoundation
import AVKit
import AppKit
@testable import AirPlayr

@MainActor final class MKVBridgeTests: XCTestCase {
    func testHEVCMKVAutomaticPlaybackTracksAndDistantSeeking() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "HEVC", withExtension: "mkv"))
        let info = try await MKVBridge.inspect(source)
        XCTAssertEqual(info.video?.codec_name, "hevc")
        XCTAssertEqual(info.streams.filter { $0.codec_type == "audio" }.count, 2)
        let tracks = try await MKVBridge.tracks(info, source: source, external: nil)
        XCTAssertEqual(tracks.audio.count, 2)
        XCTAssertEqual(tracks.subtitles.count, 2)
        let service = PlaybackService(library: LibraryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false
        service.open(source)
        try await waitUntil { service.player.currentItem?.status == .readyToPlay && !service.isPreparingForTV && service.phase != .seeking || service.phase == .failed }
        XCTAssertNotEqual(service.phase, .failed, service.issue ?? "")
        XCTAssertTrue(service.isCompatibilityStreaming)
        XCTAssertEqual(service.duration ?? 0, info.duration ?? 0, accuracy: 0.05)
        XCTAssertEqual(service.audioGroup?.options.count, 2)
        XCTAssertEqual(service.subtitleGroup?.options.count, 2)
        for target in [1.2, 8.0, 2.0, 12.0] {
            service.seek(to: target)
            try await waitUntil { service.phase != .seeking }
            XCTAssertEqual(service.position, target, accuracy: 0.15)
            XCTAssertEqual(service.player.rate, 0)
            service.togglePlayback()
            try await waitUntil { service.position > target + 0.4 || service.phase == .failed }
            XCTAssertNotEqual(service.phase, .failed, service.issue ?? "")
            service.togglePlayback()
        }
        service.stop()
        XCTAssertNil(service.player.currentItem)
    }
    func testRepositoryBunnyMKVFirstAndUncachedSections() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Bunny-h265", withExtension: "mkv"))
        let began = Date()
        let session = AutomaticStreamSession(source: source, start: 0, subtitles: nil)
        defer { session.stop() }
        let url = try await session.prepare(host: "127.0.0.1", onFailure: { _ in })
        print("MKV source initial preparation seconds", Date().timeIntervalSince(began))
        let preparedCount = await session.store?.cachedSegmentCount
        XCTAssertEqual(preparedCount, 1, "Startup must prepare one section, not the complete movie")
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let video = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        video.controlsStyle = .none; video.player = player; window.contentView = video; window.orderFront(nil)
        defer { player.pause(); player.replaceCurrentItem(with: nil); window.close() }
        try await waitUntil { player.currentItem?.status == .readyToPlay || player.currentItem?.status == .failed }
        XCTAssertNil(player.currentItem?.error)
        for target in [0.5, 8.0, 3.0] {
            player.pause()
            var done: Bool?
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { value in Task { @MainActor in done = value } }
            try await waitUntil { done != nil }
            XCTAssertEqual(done, true)
            XCTAssertEqual(player.currentTime().seconds, target, accuracy: 0.2)
            player.playImmediately(atRate: 1)
            try await waitUntil { player.currentTime().seconds > target + 0.4 || player.currentItem?.status == .failed }
            XCTAssertNil(player.currentItem?.error)
        }
    }
    func testInvalidMKVAndHelperOutputLimit() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mkv")
        try Data("not a movie".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do { _ = try await MKVBridge.inspect(file); XCTFail("Malformed MKV must fail") } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        do { _ = try await MediaToolRunner.run("ffprobe", arguments: ["-version"], limit: 8); XCTFail("Output cap must apply") } catch { XCTAssertTrue(error.localizedDescription.contains("limit")) }
    }
    func testCancellationStopsHelperPromptly() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "HEVC", withExtension: "mkv"))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let started = Date()
        let task = Task {
            try await MediaToolRunner.run("ffmpeg", arguments: ["-v", "error", "-nostdin", "-protocol_whitelist", "file,pipe,fd", "-readrate", "0.01", "-i", "fd:", "-t", "6", "-map", "0:v:0", "-c:v", "copy", "-tag:v", "hvc1", "-an", "-sn", "-f", "mp4", output.path], input: source)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must reach the helper") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testHEVCRemuxIsPlayableAndPreservesOriginalFile() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "HEVC", withExtension: "mkv"))
        let before = try Data(contentsOf: source)
        let section = try await MKVBridge.section(source: source, start: 7.25, length: 6)
        defer { section.remove() }
        let asset = AVURLAsset(url: section.url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let formats = try await video.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_HEVC)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "Only the requested audio stream should be transcoded per section")
        XCTAssertEqual(try Data(contentsOf: source), before)
        let directory = section.directory
        section.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testHev1NormalizationPreservesEmbeddedTimedText() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Bunny-hev1-tracks", withExtension: "mp4"))
        let info = try await MKVBridge.inspect(source)
        let tracks = try await MKVBridge.tracks(info, source: source, external: nil)
        XCTAssertEqual(tracks.subtitles.count, 2)
        XCTAssertEqual(tracks.subtitles[0].document.text(at: 1.5), "ENGLISH TEST CAPTION")
        let service = PlaybackService(library: LibraryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false
        service.open(source)
        try await waitUntil { service.player.currentItem?.status == .readyToPlay && !service.isPreparingForTV && service.phase != .seeking || service.phase == .failed }
        XCTAssertNotEqual(service.phase, .failed, service.issue ?? "")
        XCTAssertTrue(service.isCompatibilityStreaming)
        XCTAssertEqual(service.subtitleGroup?.options.count, 2)
    }
    func testRepeatedPreparationCancellationRemovesCaches() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Bunny-h264", withExtension: "mkv"))
        for delay: UInt64 in [30_000_000, 150_000_000, 350_000_000, 600_000_000] {
            let session = AutomaticStreamSession(source: source, start: 0, subtitles: nil)
            let preparation = Task { try await session.prepare(host: "127.0.0.1", onFailure: { _ in }) }
            try await Task.sleep(nanoseconds: delay)
            let directory = await session.store?.cacheURL
            preparation.cancel(); session.stop()
            _ = await preparation.result
            if let directory { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)) }
        }
    }
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard condition() else {
            XCTFail("Timed out waiting for real MKV playback", file: file, line: line)
            throw StreamFailure(message: "MKV playback test timed out")
        }
    }
}
