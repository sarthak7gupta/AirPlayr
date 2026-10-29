import XCTest
import AVFoundation
import AVKit
import VideoToolbox
@testable import AirPlayr

/// All inputs originate in the checked-in Fixtures folder. Derivatives are temporary and lossless.
@MainActor final class FormatMatrixTests: XCTestCase {
    func testH264MP4() async throws { try await verify(codec: "h264", container: "mp4") }
    func testH264MKV() async throws { try await verify(codec: "h264", container: "mkv") }
    func testH264M4V() async throws { try await verify(codec: "h264", container: "m4v") }
    func testH264MOV() async throws { try await verify(codec: "h264", container: "mov") }
    func testHEVCMP4() async throws { try await verify(codec: "h265", container: "mp4") }
    func testHEVCMKV() async throws { try await verify(codec: "h265", container: "mkv") }
    func testHEVCM4V() async throws { try await verify(codec: "h265", container: "m4v") }
    func testHEVCMOV() async throws { try await verify(codec: "h265", container: "mov") }
    func testWAV() async throws { try await verifyAudio("wav") }
    func testAAC() async throws { try await verifyAudio("aac") }
    func testM4AAAC() async throws { try await verifyAudio("m4a") }
    func testMP3() async throws { try await verifyAudio("mp3") }
    func testAIFF() async throws { try await verifyAudio("aiff") }
    func testCAF() async throws { try await verifyAudio("caf") }
    func testFLAC() async throws { try await verifyAudio("flac") }

    func testExtendedFormatsSupportOnMac() async throws {
        for ext in ["m2ts", "ts", "mts", "m3u8", "ac4", "vob", "iso"] {
            XCTAssertTrue(MediaPolicy.extensions.contains(ext), "MediaPolicy must support \(ext)")
            XCTAssertTrue(PlaybackService.supportedMediaExtensions.contains(ext), "PlaybackService must support \(ext)")
        }
        for bridgeExt in ["m2ts", "ts", "mts", "vob", "ac4"] {
            let dummy = URL(fileURLWithPath: "/tmp/sample." + bridgeExt)
            XCTAssertTrue(MKVBridge.requiresBridge(dummy), "MKVBridge must require bridge for \(bridgeExt)")
        }
    }

    func testAV1ExistingAppleDecoderCapability() async throws {
        let source = try fixture("Big Buck Bunny 1080p_av1", "mp4")
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) else { throw XCTSkip("AV1 is unavailable on this hardware; no software AV1 decoder is bundled") }
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isPlayable)) == true else { throw XCTSkip("Current Apple media engine rejects the supplied AV1 fixture; no decoder was added") }
        let image: CGImage
        do { image = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 1, preferredTimescale: 600)).image }
        catch { throw XCTSkip("Current Apple engine could not decode an AV1 frame: \(PlaybackDiagnostics.code(error))") }
        XCTAssertEqual(image.width, 1920); XCTAssertEqual(image.height, 1080)
        try await verifyPlayer(source, video: true)
        print("AV1 EXISTING ENGINE: frame decoded and playback/seek passed")
    }
    func testMislabelledMKVIsNotUsedToClaimMatroskaSupport() async throws {
        let source = try fixture("Big Buck Bunny 1080p_h264", "mkv")
        let header = try Data(contentsOf: source).prefix(12)
        XCTAssertEqual(String(data: header.dropFirst(4).prefix(4), encoding: .ascii), "ftyp", "The supplied .mkv is an MP4 internally; genuine MKVs are separate fixtures")
    }
    private func verify(codec: String, container: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try fixture("Big Buck Bunny 1080p_" + codec, "mp4")
        let source: URL
        if container == "mp4" { source = base }
        else if container == "mkv" {
            source = try fixture("Bunny-" + codec, "mkv")
            XCTAssertEqual(Array(try Data(contentsOf: source).prefix(4)), [0x1a, 0x45, 0xdf, 0xa3])
        } else {
            source = try fixture("Bunny-" + codec, container)
        }
        try await verifyPlayer(source, video: true)
        // Verify the actual TV-compatible engine locally, independently of receiver availability.
        let stream = AutomaticStreamSession(source: source, start: 0, subtitles: nil)
        defer { stream.stop() }
        let url = try await stream.prepare(host: "127.0.0.1", onFailure: { _ in })
        let asset = AVURLAsset(url: url)
        let streamDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(streamDuration, 10, accuracy: 0.1)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.allowsExternalPlayback = false; player.isMuted = true
        let window = videoWindow(player)
        defer { player.pause(); player.replaceCurrentItem(with: nil); window.close() }
        try await waitUntil { player.currentItem?.status == .readyToPlay || player.currentItem?.status == .failed }
        XCTAssertNil(player.currentItem?.error)
        try await seek(player, to: 7)
        player.playImmediately(atRate: 1)
        try await waitUntil { player.currentTime().seconds > 7.3 || player.currentItem?.status == .failed }
        XCTAssertNil(player.currentItem?.error)
        print("FORMAT MATRIX PASSED", codec, container, "local and compatible HTTP playback/seek")
    }
    private func verifyAudio(_ ext: String) async throws { try await verifyPlayer(fixture("Tone", ext), video: false) }
    private func verifyPlayer(_ source: URL, video: Bool) async throws {
        let service = PlaybackService(library: LibraryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false; service.player.isMuted = true
        let window = video ? videoWindow(service.player) : nil
        defer { window?.close() }
        service.open(source)
        try await waitUntil { service.player.currentItem?.status == .readyToPlay && !service.isPreparingForTV && service.phase != .seeking || service.phase == .failed }
        XCTAssertNotEqual(service.phase, .failed, service.issue ?? "")
        guard service.phase != .failed else { throw MediaIssue.unsupported }
        service.seek(to: 1)
        try await waitUntil { service.phase != .seeking }
        XCTAssertEqual(service.position, 1, accuracy: 0.2)
        service.togglePlayback()
        try await waitUntil { service.position > 1.3 || service.phase == .failed }
        XCTAssertNotEqual(service.phase, .failed, service.issue ?? "")
        service.togglePlayback()
    }
    private func fixture(_ name: String, _ ext: String) throws -> URL { try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)) }
    private func videoWindow(_ player: AVPlayer) -> NSWindow {
        let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360)); view.controlsStyle = .none; view.player = player
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        return window
    }
    private func seek(_ player: AVPlayer, to seconds: Double) async throws {
        var result: Bool?
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { value in Task { @MainActor in result = value } }
        try await waitUntil { result != nil }
        XCTAssertEqual(result, true)
    }
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard condition() else { XCTFail("Timed out waiting for actual fixture playback", file: file, line: line); throw MediaIssue.unsupported }
    }
}
