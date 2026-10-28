import XCTest
import AVFoundation
@testable import AirPlayr

final class MediaTests: XCTestCase {
    func testModelRoundTrip() throws {
        let entry = MediaEntry(title: "A Movie", bookmark: Data([1, 2]))
        XCTAssertEqual(try JSONDecoder().decode(MediaEntry.self, from: JSONEncoder().encode(entry)), entry)
    }
    func testSeekBoundsAndUnknownDuration() {
        XCTAssertEqual(MediaPolicy.seekTarget(-10, duration: 90), 0)
        XCTAssertEqual(MediaPolicy.seekTarget(100, duration: 90), 90)
        XCTAssertEqual(MediaPolicy.seekTarget(12.5, duration: 90), 12.5)
        XCTAssertNil(MediaPolicy.seekTarget(2, duration: .infinity))
        XCTAssertNil(MediaPolicy.seekTarget(.nan, duration: 90))
        XCTAssertNil(MediaPolicy.seekTarget(2, duration: 0))
    }
    func testTimeFormatting() {
        XCTAssertEqual(MediaPolicy.time(.nan), "—:—")
        XCTAssertEqual(MediaPolicy.time(3661), "1:01:01")
        XCTAssertEqual(MediaPolicy.time(61), "1:01")
    }
    func testFileValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mp4 = directory.appendingPathComponent("test.MP4")
        try Data().write(to: mp4)
        XCTAssertNoThrow(try MediaPolicy.validate(mp4)) // Extension is not proof of playability.
        let mkv = directory.appendingPathComponent("test.mkv")
        try Data().write(to: mkv)
        XCTAssertNoThrow(try MediaPolicy.validate(mkv)) // The bridge validates actual tracks asynchronously.
        let unknown = directory.appendingPathComponent("test.unknown")
        try Data().write(to: unknown)
        XCTAssertThrowsError(try MediaPolicy.validate(unknown)) { XCTAssertEqual($0 as? MediaIssue, .unsupported) }
        XCTAssertThrowsError(try MediaPolicy.validate(directory))
        XCTAssertThrowsError(try MediaPolicy.validate(directory.appendingPathComponent("missing.mp4"))) { XCTAssertEqual($0 as? MediaIssue, .unreadable) }
    }
    func testActionableErrors() {
        XCTAssertTrue(MediaIssue.unsupported.localizedDescription.contains("MP4"))
        XCTAssertTrue(MediaIssue.unreadable.localizedDescription.contains("Open it again"))
    }
}

final class SubtitleTests: XCTestCase {
    private let srt = "1\r\n00:00:01,000 --> 00:00:03,000\r\n<i>Hello</i>\r\nworld\r\n\r\n2\r\n00:00:02,500 --> 00:00:04,000\r\nSecond"
    func testParsingOverlapAndSeekSynchronization() throws {
        let doc = try SubtitleDocument.parse(srt)
        XCTAssertEqual(doc.text(at: 0), "")
        XCTAssertEqual(doc.text(at: 1), "Hello\nworld")
        XCTAssertEqual(doc.text(at: 2.8), "Hello\nworld\nSecond")
        XCTAssertEqual(doc.text(at: 3), "Second")
        XCTAssertEqual(doc.text(at: 10), "")
        XCTAssertEqual(doc.text(at: 1.2), "Hello\nworld")
    }
    func testMalformedCuesRejected() {
        for text in ["", "hello", "1\n00:99:00,000 --> 00:00:03,000\nNo", "1\n00:00:05,000 --> 00:00:03,000\nNo", "1\n00:00:01,000 --> 00:00:03,000"] {
            XCTAssertThrowsError(try SubtitleDocument.parse(text))
        }
    }
    func testTrailingCueSettingsAndEmptySpacerCuesTolerated() throws {
        let input = "1\n00:00:01,000 --> 00:00:02,000\n\n2\n00:00:02,000 --> 00:00:04,000 line:85% position:50%\nPositioned caption"
        let doc = try SubtitleDocument.parse(input)
        XCTAssertEqual(doc.cues.count, 1)
        XCTAssertEqual(doc.text(at: 2.5), "Positioned caption")
    }
    func testAbandonedTemporaryCacheCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AirPlayr-CleanupTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vod = root.appendingPathComponent("AirPlayr-VOD-123", isDirectory: true)
        let mkv = root.appendingPathComponent("AirPlayr-MKV-456", isDirectory: true)
        let exp = root.appendingPathComponent("AirPlayr-Export-789", isDirectory: true)
        let keep = root.appendingPathComponent("Unrelated-Folder", isDirectory: true)
        for dir in [vod, mkv, exp, keep] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        TemporaryCacheCleanup.removeAbandonedCaches(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vod.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mkv.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }
    func testEncodingAndUnsupportedTypes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".srt")
        defer { try? FileManager.default.removeItem(at: url) }
        try srt.data(using: .utf16)?.write(to: url)
        XCTAssertEqual(try SubtitleDocument.read(url).cues.count, 2)
        try Data([0xff, 0x80, 0x81]).write(to: url)
        XCTAssertThrowsError(try SubtitleDocument.read(url))
    }
}

@MainActor final class LibraryTests: XCTestCase {
    func testPersistenceRecentsDedupAndRemoval() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sample.mp4")
        try Data().write(to: url)
        let file = folder.appendingPathComponent("library.json")
        let store = LibraryStore(file: file)
        let entry = try store.remember(url)
        store.update(entry.id, position: 42, duration: 90)
        _ = try store.remember(url)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.position, 42)
        let restored = LibraryStore(file: file)
        XCTAssertEqual(restored.entries, store.entries)
        XCTAssertEqual(try restored.resolve(entry), url)
        restored.remove(entry.id)
        XCTAssertTrue(LibraryStore(file: file).entries.isEmpty)
    }
    func testCorruptPersistenceIsVisible() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("invalid".utf8).write(to: file)
        XCTAssertNotNil(LibraryStore(file: file).issue)
    }
}

@MainActor final class PlaybackTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool, seconds: Double = 8) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !predicate() && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(predicate(), "Timed out waiting for player state")
    }
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 4))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { samples[i] = 0 } // Silent fixture avoids audible disruption.
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
    func testRealLocalPlaybackPausedAndPlayingSeeksAndCleanup() async throws {
        let url = try fixture()
        let libraryURL = url.deletingPathExtension().appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: libraryURL) }
        let library = LibraryStore(file: libraryURL)
        var service: PlaybackService? = PlaybackService(library: library)
        weak var weakService = service
        let player = try XCTUnwrap(service?.player)
        service?.open(url)
        try await waitUntil { service?.player.currentItem?.status == .readyToPlay }
        XCTAssertNil(service?.issue)
        XCTAssertEqual(service?.duration ?? 0, 4, accuracy: 0.1)
        service?.seek(to: 2)
        try await waitUntil { service?.phase != .seeking }
        XCTAssertEqual(player.currentTime().seconds, 2, accuracy: 0.15)
        XCTAssertEqual(player.rate, 0)
        service?.togglePlayback()
        try await waitUntil { player.timeControlStatus == .playing }
        service?.seek(to: 1)
        try await waitUntil { service?.phase == .playing }
        XCTAssertEqual(player.currentTime().seconds, 1, accuracy: 0.5)
        service?.togglePlayback()
        XCTAssertEqual(player.rate, 0)
        service?.stop()
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(service?.phase, .empty)
        service?.shutdown(); service = nil
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(weakService)
        weakService = nil
    }
    func testFailureAndRapidReplacement() async throws {
        let url = try fixture()
        let libraryURL = url.deletingPathExtension().appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: libraryURL) }
        let service = PlaybackService(library: LibraryStore(file: libraryURL))
        defer { service.shutdown() }
        service.open(url.appendingPathExtension("missing"))
        try await waitUntil { service.phase == .failed }
        XCTAssertNotNil(service.issue)
        service.open(url)
        service.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(service.phase, .empty)
        XCTAssertNil(service.player.currentItem)
    }
    func testExternalSubtitleSelectionAndOff() async throws {
        let url = try fixture()
        let srt = url.deletingPathExtension().appendingPathExtension("srt")
        let libraryURL = url.deletingPathExtension().appendingPathExtension("json")
        defer { for file in [url, srt, libraryURL] { try? FileManager.default.removeItem(at: file) } }
        try "1\n00:00:01,000 --> 00:00:03,000\nHello".write(to: srt, atomically: true, encoding: .utf8)
        let service = PlaybackService(library: LibraryStore(file: libraryURL))
        defer { service.shutdown() }
        service.open(url)
        try await waitUntil { service.player.currentItem?.status == .readyToPlay }
        service.loadSubtitles(srt)
        try await waitUntil { service.externalSubtitles != nil }
        service.seek(to: 2)
        try await waitUntil { service.phase != .seeking }
        XCTAssertEqual(service.subtitleText, "Hello")
        service.seek(to: 0)
        try await waitUntil { service.phase != .seeking }
        XCTAssertEqual(service.subtitleText, "")
        XCTAssertNotNil(service.externalSubtitles)
        service.selectSubtitle(nil)
        XCTAssertNil(service.externalSubtitles)
        XCTAssertNil(service.subtitleSelection)
    }
}

@MainActor final class ExportTests: XCTestCase {
    func testConcurrentExportsNeverDeleteWinningDestination() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("shared.mp4")
        let first = Task { () -> Bool in
            do { try await CompatibleExportService.export(source: source, destination: destination, subtitles: nil); return true }
            catch { return false }
        }
        let second = Task { () -> Bool in
            do { try await CompatibleExportService.export(source: source, destination: destination, subtitles: nil); return true }
            catch { return false }
        }
        let results = await [first.value, second.value]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let playable = try await AVURLAsset(url: destination).load(.isPlayable)
        XCTAssertTrue(playable)
    }
    func testH264ExportWithBurnedSubtitlesAndNoOverwrite() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("export.mp4")
        let doc = try SubtitleDocument.parse("1\n00:00:01,000 --> 00:00:03,000\nAIRPLAYR SUBTITLE TEST")
        try await CompatibleExportService.export(source: source, destination: output, subtitles: doc)
        let asset = AVURLAsset(url: output)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_H264)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertLessThanOrEqual(size.width, 1280)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let before = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let during = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        let after = try await generator.image(at: CMTime(seconds: 3.5, preferredTimescale: 600)).image
        for (name, image) in [("Before subtitle", before), ("Subtitle visible", during), ("After subtitle", after)] {
            let attachment = XCTAttachment(image: NSImage(cgImage: image, size: .zero))
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        // White text exists only in the cue interval. The synthetic source has no white pixels.
        XCTAssertLessThan(whitePixels(before), 50)
        XCTAssertGreaterThan(whitePixels(during), 100)
        XCTAssertLessThan(whitePixels(after), 50)
        do {
            try await CompatibleExportService.export(source: source, destination: output, subtitles: nil)
            XCTFail("Must not overwrite existing output")
        } catch { XCTAssertTrue(error.localizedDescription.contains("new filename")) }
    }
    private func whitePixels(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 220 && bytes[$0+1] > 220 && bytes[$0+2] > 220 }.count
    }
    func testDiagnosticsRedactPrivateDetails() {
        let error = NSError(domain: AVFoundationErrorDomain, code: -11870, userInfo: [NSLocalizedDescriptionKey: "/Users/private/movie.mp4", NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -17226)])
        XCTAssertEqual(PlaybackDiagnostics.code(error), "AVFoundationErrorDomain -11870 → NSOSStatusErrorDomain -17226")
        XCTAssertTrue(PlaybackDiagnostics.guidance(error, external: true).contains("Local Network"))
    }
    func testVolumeBoundsAndMute() {
        let service = PlaybackService(library: LibraryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { service.shutdown() }
        service.adjustVolume(2); XCTAssertEqual(service.volume, 1)
        service.adjustVolume(-2); XCTAssertEqual(service.volume, 0)
        service.toggleMute(); XCTAssertTrue(service.player.isMuted)
        service.adjustVolume(0.05); XCTAssertFalse(service.player.isMuted)
        XCTAssertEqual(service.player.volume, 0.05, accuracy: 0.001)
    }
    func testLibraryPrivateModeResetProgressAndMaxItems() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let libraryFile = tempDir.appendingPathComponent("library.json")
        let store = LibraryStore(file: libraryFile)
        let prevPrivate = store.isPrivateMode
        defer { store.isPrivateMode = prevPrivate }
        store.isPrivateMode = false

        let f1 = tempDir.appendingPathComponent("MovieOne.mp4")
        try Data([0x00, 0x01]).write(to: f1)
        let entry1 = try store.remember(f1)
        XCTAssertEqual(store.entries.count, 1)
        store.update(entry1.id, position: 120, duration: 600)
        XCTAssertEqual(store.entries.first?.position, 120)
        store.resetProgress(entry1.id)
        XCTAssertEqual(store.entries.first?.position, 0)

        // Private mode should not append new entries to the persisted list
        store.isPrivateMode = true
        let f2 = tempDir.appendingPathComponent("PrivateMovie.mp4")
        try Data([0x00, 0x02]).write(to: f2)
        _ = try store.remember(f2)
        XCTAssertEqual(store.entries.count, 1)
    }
}
