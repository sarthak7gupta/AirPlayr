import XCTest
import AVFoundation
import MediaPlayer
@testable import AirPlayr

@MainActor final class PlayerOptionsTests: XCTestCase {
    func testMatchingSRTLoadsAutomaticallyAndOffSurvivesSeek() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Movie.with.dots.mp4")
        try FileManager.default.copyItem(at: fixture, to: source)
        let companion = SubtitleDocument.companionURL(for: source)
        XCTAssertEqual(companion.lastPathComponent, "Movie.with.dots.srt")
        try "1\n00:00:00,000 --> 00:00:04,000\nAutomatic captions".write(to: companion, atomically: true, encoding: .utf8)
        let service = PlaybackService(library: LibraryStore(file: folder.appendingPathComponent("library.json")))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false
        service.open(source)
        try await waitUntil { service.externalSubtitles != nil }
        XCTAssertEqual(service.externalSubtitleName, "Movie.with.dots.srt")
        XCTAssertEqual(service.externalSubtitles?.text(at: 2), "Automatic captions")
        service.selectSubtitle(nil)
        service.seek(to: 2)
        try await waitUntil { service.phase != .seeking }
        XCTAssertNil(service.externalSubtitles)
        service.open(fixture)
        try await waitUntil { service.player.currentItem?.status == .readyToPlay }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(service.externalSubtitles)
        XCTAssertNil(service.issue, "A missing sibling SRT is normal")
    }
    func testRateSelectionAndPausedIntent() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let service = PlaybackService(library: LibraryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false
        service.open(source)
        try await waitUntil { service.player.currentItem?.status == .readyToPlay }
        service.setPlaybackRate(1.5)
        XCTAssertEqual(service.player.rate, 0)
        service.togglePlayback()
        try await waitUntil { service.actualPlaybackRate == 1.5 }
        service.setPlaybackRate(0.75)
        try await waitUntil { service.actualPlaybackRate == 0.75 }
        service.setPlaybackRate(4)
        try await waitUntil { service.actualPlaybackRate == 4 }
        service.togglePlayback()
        service.stepPlaybackRate(increase: true)
        XCTAssertEqual(service.playbackRate, 4)
        service.stepPlaybackRate(increase: false)
        XCTAssertEqual(service.playbackRate, 3.75)
        XCTAssertEqual(service.player.rate, 0)
        for _ in 0..<20 { service.stepPlaybackRate(increase: false) }
        XCTAssertEqual(service.playbackRate, 0.5)
        service.stepPlaybackRate(increase: true)
        XCTAssertEqual(service.playbackRate, 0.75)
        service.setPlaybackRate(-1)
        service.setPlaybackRate(4.25)
        service.setPlaybackRate(1.1)
        XCTAssertEqual(service.playbackRate, 0.75)
        XCTAssertEqual(service.player.rate, 0)
    }
    func testCaptionAppearanceChangesEncodedPositionAndWidth() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let doc = try SubtitleDocument.parse("1\n00:00:01,000 --> 00:00:03,000\nA longer caption wraps within the selected subtitle width.")
        var top = SubtitleAppearance(); top.width = .compact; top.position = .top; top.background = .outline
        XCTAssertEqual(try JSONDecoder().decode(SubtitleAppearance.self, from: JSONEncoder().encode(top)), top)
        var regions: [CGRect] = []
        for style in [SubtitleAppearance(), top] {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            try await CompatibleExportService.export(source: source, destination: output, subtitles: doc, appearance: style)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            let image = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
            let rect = try textBounds(image)
            XCTAssertLessThanOrEqual(rect.width, CGFloat(image.width) * style.width.fraction)
            regions.append(rect)
        }
        XCTAssertGreaterThan(abs(regions[0].midY - regions[1].midY), 150)
    }
    func testPackagedIconExists() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "AirPlayrIcon", withExtension: "icns"))
        XCTAssertNotNil(NSImage(contentsOf: url))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, "AirPlayrIcon")
    }
    func testPreventSleepWhilePlayingSettingAndAssertionLifecycle() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        UserDefaults.standard.removeObject(forKey: "preventSleepWhilePlaying")
        defer { UserDefaults.standard.removeObject(forKey: "preventSleepWhilePlaying") }
        let service = PlaybackService(library: LibraryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false
        XCTAssertTrue(service.preventSleepWhilePlaying)
        XCTAssertFalse(service.isPreventingSleep)
        service.open(source)
        try await waitUntil { service.player.currentItem?.status == .readyToPlay }
        XCTAssertFalse(service.isPreventingSleep)
        service.togglePlayback()
        try await waitUntil { service.phase == .playing }
        XCTAssertTrue(service.isPreventingSleep, "Active playback must hold an IOKit sleep assertion when enabled")
        service.setPreventSleepWhilePlaying(false)
        XCTAssertFalse(service.preventSleepWhilePlaying)
        XCTAssertFalse(service.isPreventingSleep, "Disabling the setting must immediately release the sleep assertion")
        service.setPreventSleepWhilePlaying(true)
        XCTAssertTrue(service.isPreventingSleep, "Re-enabling while playing must re-acquire the sleep assertion")
        service.togglePlayback()
        try await waitUntil { service.phase == .paused }
        XCTAssertFalse(service.isPreventingSleep, "Pausing playback must release the sleep assertion")
    }
    func testChromecastProtobufFramingAndMiracastDLNASOAP() throws {
        let original = CastV2Protocol.Message(
            sourceID: "sender-0",
            destinationID: "receiver-0",
            namespace: CastV2Protocol.mediaNamespace,
            payloadUTF8: CastV2Protocol.loadPayload(
                requestID: 42,
                mediaSessionUrl: try XCTUnwrap(URL(string: "http://192.168.1.10:54321/token/index.m3u8")),
                title: "Movie \"Night\"",
                position: 12.5
            )
        )
        let encoded = CastV2Protocol.encode(original)
        let decoded = try XCTUnwrap(CastV2Protocol.decode(encoded))
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.payloadUTF8.contains(#""contentId":"http://192.168.1.10:54321/token/index.m3u8""#))
        XCTAssertTrue(decoded.payloadUTF8.contains(#""title":"Movie \"Night\"""#))

        let soap = String(decoding: CastV2Protocol.dlnaSetAVTransportSOAP(
            streamURL: try XCTUnwrap(URL(string: "http://192.168.1.10:54321/token/index.m3u8?a=1&b=2")),
            title: "A & B <Movie>"
        ), as: UTF8.self)
        XCTAssertTrue(soap.contains("SetAVTransportURI"))
        XCTAssertTrue(soap.contains("http://192.168.1.10:54321/token/index.m3u8?a=1&amp;b=2"))
        XCTAssertFalse(soap.contains("<Movie>"))

        let cast = CastService()
        let chromecast = cast.addManualDevice(name: "Living Room TV", host: "127.0.0.1", port: 8009, kind: .chromecast)
        let miracast = cast.addManualDevice(name: "Office Display", host: "127.0.0.1", port: 1400, kind: .miracastDLNA)
        XCTAssertEqual(cast.devices.count, 2)
        XCTAssertEqual(chromecast.kind, .chromecast)
        XCTAssertEqual(miracast.kind, .miracastDLNA)
        XCTAssertNotNil(miracast.controlURL)
        cast.disconnect()
        XCTAssertNil(cast.activeDevice)
    }
    func testMacOSLastThreeVersionsAndBetaCompatibility() throws {
        // Current rolling window: macOS 27, macOS 26, and macOS 15 (plus latest macOS public beta).
        let minOSString = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String)
        let major = try XCTUnwrap(Int(minOSString.split(separator: ".").first ?? ""))
        XCTAssertLessThanOrEqual(major, 15, "Deployment target (\(minOSString)) must support macOS 15, 26, 27, and public beta")
        let bonjour = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])
        XCTAssertTrue(bonjour.contains("_googlecast._tcp"))
    }
    func testQueueNavigationAndFolderExpansion() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QueueTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ep1 = folder.appendingPathComponent("01_Episode.mp4")
        let ep2 = folder.appendingPathComponent("02_Episode.mp4")
        let ep3 = folder.appendingPathComponent("03_Episode.mkv")
        try FileManager.default.copyItem(at: fixture, to: ep1)
        try FileManager.default.copyItem(at: fixture, to: ep2)
        try FileManager.default.copyItem(at: fixture, to: ep3)

        let expanded = PlaybackService.expandMediaURLs([folder])
        XCTAssertEqual(expanded.map(\.lastPathComponent), ["01_Episode.mp4", "02_Episode.mp4", "03_Episode.mkv"])

        let service = PlaybackService(library: LibraryStore(file: folder.appendingPathComponent("library.json")))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false
        service.openFiles([ep1, ep2])
        XCTAssertEqual(service.queue.count, 2)
        XCTAssertEqual(service.queueIndex, 0)
        XCTAssertFalse(service.canPlayPrevious)
        XCTAssertTrue(service.canPlayNext)

        service.enqueue([ep3])
        XCTAssertEqual(service.queue.count, 3)

        service.playNext()
        XCTAssertEqual(service.queueIndex, 1)
        XCTAssertEqual(service.title, "02_Episode")
        XCTAssertTrue(service.canPlayPrevious)
        XCTAssertTrue(service.canPlayNext)

        service.playPrevious()
        XCTAssertEqual(service.queueIndex, 0)
        XCTAssertEqual(service.title, "01_Episode")

        service.removeFromQueue(at: 2)
        XCTAssertEqual(service.queue.count, 2)
        service.clearQueue()
        XCTAssertEqual(service.queue.count, 1)
    }
    func testSubtitleSyncOffsetAndASSOverrideTagStripping() throws {
        let assConverted = """
        1
        00:00:02,000 --> 00:00:05,000
        {\\an8}{\\pos(192,220)}First line\\NSecond line
        """
        let doc = try SubtitleDocument.parse(assConverted)
        XCTAssertEqual(doc.cues.count, 1)
        XCTAssertEqual(doc.cues[0].text, "First line\nSecond line")

        let shiftedForward = doc.shifted(by: 0.5)
        XCTAssertEqual(shiftedForward.cues[0].start, 2.5, accuracy: 0.001)
        XCTAssertEqual(shiftedForward.cues[0].end, 5.5, accuracy: 0.001)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OffsetTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = PlaybackService(library: LibraryStore(file: folder.appendingPathComponent("library.json")))
        defer { service.shutdown() }
        service.adjustSubtitleOffset(by: 0.25)
        service.adjustSubtitleOffset(by: 0.25)
        XCTAssertEqual(service.subtitleOffsetSeconds, 0.5, accuracy: 0.001)
        service.resetSubtitleOffset()
        XCTAssertEqual(service.subtitleOffsetSeconds, 0.0, accuracy: 0.001)
    }
    func testNowPlayingInfoCenterAndRemoteCommands() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let service = PlaybackService(library: LibraryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false
        service.openFiles([source])
        try await waitUntil { service.player.currentItem?.status == .readyToPlay }
        service.updateNowPlayingInfo()
        let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Video")
        XCTAssertTrue(MPRemoteCommandCenter.shared().togglePlayPauseCommand.isEnabled)
    }
    func testSSDPAndUPnPDeviceXMLParsing() throws {
        let ssdpResponse = """
        HTTP/1.1 200 OK\r
        CACHE-CONTROL: max-age=1800\r
        LOCATION: http://192.168.1.77:1400/xml/device_description.xml\r
        ST: urn:schemas-upnp-org:device:MediaRenderer:1\r
        \r
        """
        let location = try XCTUnwrap(CastV2Protocol.parseSSDPLocation(ssdpResponse))
        XCTAssertEqual(location.absoluteString, "http://192.168.1.77:1400/xml/device_description.xml")

        let xml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <device>
            <friendlyName>Bedroom LG OLED</friendlyName>
            <modelName>LG WebOS TV</modelName>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                <controlURL>/MediaRenderer/AVTransport/Control</controlURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
        let device = try XCTUnwrap(CastV2Protocol.parseUPnPDeviceXML(Data(xml.utf8), baseURL: location))
        XCTAssertEqual(device.name, "Bedroom LG OLED")
        XCTAssertEqual(device.model, "LG WebOS TV")
        XCTAssertEqual(device.kind, .miracastDLNA)
        XCTAssertEqual(device.controlURL?.absoluteString, "http://192.168.1.77:1400/MediaRenderer/AVTransport/Control")
    }
    func testOpenSubtitlesMovieHashAndResponseParsing() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("HashTest-" + UUID().uuidString + ".bin")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        // 128 KB of zeros -> hash should equal fileSize (131072 = 0x20000 -> "0000000000020000")
        let data = Data(repeating: 0, count: 131_072)
        try data.write(to: tempFile)
        let hash = try OpenSubtitlesService.computeMovieHash(for: tempFile)
        XCTAssertEqual(hash, "0000000000020000")

        let sampleJSON = """
        {
          "data": [
            {
              "id": "sub-1",
              "attributes": {
                "language": "en",
                "download_count": 1240,
                "release": "Sample.Movie.2026.1080p",
                "moviehash_match": true,
                "files": [
                  { "file_id": 98765, "file_name": "Sample.Movie.2026.srt" }
                ]
              }
            }
          ]
        }
        """
        let results = OpenSubtitlesService.parseSearchResponse(Data(sampleJSON.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].fileID, 98765)
        XCTAssertEqual(results[0].language, "en")
        XCTAssertTrue(results[0].hashMatch)
    }
    private func textBounds(_ image: CGImage) throws -> CGRect {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var rect = CGRect.null
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i] > 220 && bytes[i+1] > 220 && bytes[i+2] > 220 {
            rect = rect.union(CGRect(x: (i/4) % image.width, y: (i/4) / image.width, width: 1, height: 1))
        }
        XCTAssertFalse(rect.isNull)
        return rect
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(predicate())
    }
}
