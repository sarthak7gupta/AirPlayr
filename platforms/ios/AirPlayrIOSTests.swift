#if os(iOS)
import Foundation
import CoreGraphics
import AVFoundation

/// Automated verification suite for the iOS / iPadOS / iPhone Fold target (`AirPlayrIOSView` + shared Swift core).
/// Compiles and runs on the Xcode iOS Simulator (`xcrun simctl spawn`).
@main
struct AirPlayrIOSTestRunner {
    static func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        if !condition() {
            fputs("FAILED [\(file):\(line)]: \(message)\n", stderr)
            exit(1)
        }
    }

    static func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        if lhs != rhs {
            fputs("FAILED [\(file):\(line)]: Expected \(rhs), got \(lhs). \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func main() async throws {
        // 1. Subtitle parsing, ASS tag stripping, and live sync offset on iOS
        let assSample = """
        1
        00:00:02,000 --> 00:00:05,000
        {\\an8}{\\pos(100,200)}iOS First Line\\NiOS Second Line
        """
        let doc = try SubtitleDocument.parse(assSample)
        assertEqual(doc.cues.count, 1, "Expected 1 cue")
        assertEqual(doc.cues[0].text, "iOS First Line\niOS Second Line", "ASS tags should be stripped")
        let shifted = doc.shifted(by: 0.25)
        assertTrue(abs(shifted.cues[0].start - 2.25) < 0.001, "Shifted start should be 2.25s")
        assertTrue(abs(shifted.cues[0].end - 5.25) < 0.001, "Shifted end should be 5.25s")
        print("✓ [iOS] testSubtitleParseASSAndSyncOffset passed")

        // 2. OpenSubtitles 64-bit movie hash & search response parser on iOS
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ios-hash-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Data(repeating: 0, count: 131_072).write(to: tempURL)
        let hash = try OpenSubtitlesService.computeMovieHash(for: tempURL)
        assertEqual(hash, "0000000000020000", "OpenSubtitles 64-bit hash mismatch")
        print("✓ [iOS] testOpenSubtitlesMovieHash passed")

        // 3. CastV2 Protobuf wire framing & UPnP/DLNA SSDP discovery parser on iOS
        let msg = CastV2Protocol.Message(
            sourceID: "sender-ios",
            destinationID: "receiver-0",
            namespace: CastV2Protocol.mediaNamespace,
            payloadUTF8: #"{"type":"PLAY","requestId":7}"#
        )
        let encoded = CastV2Protocol.encode(msg)
        let decoded = CastV2Protocol.decode(encoded)
        assertEqual(decoded, msg, "CastV2 Protobuf roundtrip failed on iOS")

        let ssdp = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.88:1400/device.xml\r\n\r\n"
        guard let loc = CastV2Protocol.parseSSDPLocation(ssdp) else {
            fputs("FAILED: Could not parse SSDP location\n", stderr)
            exit(1)
        }
        let xml = """
        <root>
          <device>
            <friendlyName>iPad Living Room OLED</friendlyName>
            <modelName>LG WebOS</modelName>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                <controlURL>/upnp/control/AVTransport1</controlURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
        let dev = CastV2Protocol.parseUPnPDeviceXML(Data(xml.utf8), baseURL: loc)
        assertEqual(dev?.name, "iPad Living Room OLED", "UPnP friendlyName mismatch")
        assertEqual(dev?.controlURL?.absoluteString, "http://192.168.1.88:1400/upnp/control/AVTransport1", "UPnP controlURL mismatch")
        print("✓ [iOS] testCastV2AndUPnPSSDPParsing passed")

        // 4. StreamHTTPServer byte-range & WebVTT generation on iOS
        let vtt = String(decoding: StreamTracks.webVTT(doc, start: 0, end: 6), as: UTF8.self)
        assertTrue(vtt.contains("WEBVTT"), "WebVTT header missing")
        assertTrue(vtt.contains("iOS First Line"), "WebVTT cue text missing")
        assertEqual(StreamHTTPServer.byteRange("bytes=0-99", count: 500), 0..<100, "Byte range 0-99 failed")
        print("✓ [iOS] testWebVTTAndHTTPByteRange passed")

        // 5. Dual-Screen / iPhone Fold / Duo posture resolution
        assertEqual(
            DualScreenPosture.resolve(containerSize: CGSize(width: 393, height: 852)),
            .singleScreen,
            "Standard portrait iPhone should resolve to singleScreen"
        )
        assertEqual(
            DualScreenPosture.resolve(containerSize: CGSize(width: 840, height: 800), hingeRect: CGRect(x: 0, y: 392, width: 840, height: 16)),
            .tabletopHorizontalHinge,
            "Horizontal hinge should resolve to tabletopHorizontalHinge"
        )
        assertEqual(
            DualScreenPosture.resolve(containerSize: CGSize(width: 840, height: 800), hingeRect: CGRect(x: 412, y: 0, width: 16, height: 800)),
            .bookVerticalHinge,
            "Vertical hinge should resolve to bookVerticalHinge"
        )
        assertEqual(
            DualScreenPosture.resolve(containerSize: CGSize(width: 393, height: 852), hasExternalDisplay: true),
            .externalDisplayExtended,
            "External display should resolve to externalDisplayExtended"
        )
        print("✓ [iOS] testDualScreenAndFoldablePostureResolution passed")

        // 6. Instantiate iOS SwiftUI view & route picker
        let _ = AirPlayrIOSView()
        let _ = IOSAirPlayRoutePicker()
        print("✓ [iOS] testAirPlayrIOSViewInstantiation passed")
        print("ALL 6 iOS SIMULATOR TESTS PASSED")
    }
}
#endif
