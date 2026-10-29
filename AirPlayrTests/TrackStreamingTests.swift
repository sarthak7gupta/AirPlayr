import XCTest
import AVFoundation
import AppKit
@testable import AirPlayr

@MainActor final class TrackStreamingTests: XCTestCase {
    func testAlternateAudioAndEmbeddedSubtitlesOverActualHTTP() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Tracks", withExtension: "mp4"))
        let tracks = try await StreamTracks.inspect(source: source, external: nil)
        XCTAssertEqual(tracks.audio.count, 2)
        XCTAssertEqual(tracks.subtitles.count, 2)
        XCTAssertTrue(tracks.notices.isEmpty)
        XCTAssertEqual(tracks.subtitles[0].document.text(at: 1.5), "ENGLISH TEST CAPTION")
        XCTAssertEqual(tracks.subtitles[1].document.text(at: 1.5), "SOUS-TITRE TEST")

        let session = AutomaticStreamSession(source: source, start: 0, subtitles: nil)
        defer { session.stop() }
        let url = try await session.prepare(host: "127.0.0.1", onFailure: { _ in })

        let (master, _) = try await URLSession.shared.data(from: url)
        let manifest = String(decoding: master, as: UTF8.self)
        XCTAssertTrue(manifest.contains("TYPE=AUDIO")); XCTAssertTrue(manifest.contains("TYPE=SUBTITLES"))
        let (captions, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("t1_0.vtt"))
        XCTAssertTrue(String(decoding: captions, as: UTF8.self).contains("00:00:01.000 --> 00:00:03.000\nSOUS-TITRE TEST"))

        let store = try XCTUnwrap(session.store)
        let audioManifest = try await store.resource("a1.m3u8")
        let subtitleManifest = try await store.resource("t1.m3u8")
        XCTAssertNotNil(audioManifest); XCTAssertNotNil(subtitleManifest)

        let initialization = try await store.resource("a1_i0.mp4")
        let media = try await store.resource("a1_s0.m4s")
        var data = try XCTUnwrap(initialization?.0); data.append(try XCTUnwrap(media?.0))

        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try data.write(to: audioURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let videoTracks = try await audioAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(audioTracks.count, 1); XCTAssertEqual(videoTracks.count, 0)
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = false
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let item = try XCTUnwrap(player.currentItem)

        let audio = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible)

        let audioGroup = try XCTUnwrap(audio), subtitleGroup = try XCTUnwrap(subtitles)
        XCTAssertEqual(audioGroup.options.count, 2); XCTAssertEqual(subtitleGroup.options.count, 2)
        let deadline = Date().addingTimeInterval(15)
        while item.status == .unknown && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        for option in audioGroup.options {
            item.select(option, in: audioGroup)
            XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: audioGroup), option)
        }
        for option in subtitleGroup.options {
            item.select(option, in: subtitleGroup)
            XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: subtitleGroup), option)
        }
        item.select(nil, in: subtitleGroup)
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: subtitleGroup))
        player.playImmediately(atRate: 1)
        let playbackDeadline = Date().addingTimeInterval(15)
        while player.currentTime().seconds < 0.5 && Date() < playbackDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThan(player.currentTime().seconds, 0.4)
        XCTAssertNil(item.error)
    }
    func testWebVTTEscapingAndTimelineAndPlaylistInjectionProtection() throws {
        let document = SubtitleDocument(cues: [SubtitleCue(start: 5, end: 8, text: "<b>& secret"), SubtitleCue(start: 12, end: 13, text: "Later")])
        let result = String(decoding: StreamTracks.webVTT(document, start: 6, end: 12), as: UTF8.self)
        XCTAssertTrue(result.contains("00:00:05.000 --> 00:00:08.000"))
        XCTAssertTrue(result.contains("&lt;b&gt;&amp; secret")); XCTAssertFalse(result.contains("Later"))
        XCTAssertEqual(StreamTracks.attribute("English\"\nINJECT\\"), "EnglishINJECT")
    }
    func testVerifiedRouteTransitionStartsPlaybackOnlyOnce() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let service = PlaybackService(library: LibraryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false
        service.open(source)
        let deadline = Date().addingTimeInterval(10)
        while service.player.currentItem?.status != .readyToPlay && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(service.player.rate, 0)
        // Inject the observed event for a state test. This is not a hardware connection test.
        service.handleExternalPlaybackChange(true)
        XCTAssertEqual(service.player.rate, 1)
        service.togglePlayback()
        XCTAssertEqual(service.player.rate, 0)
        service.handleExternalPlaybackChange(true)
        XCTAssertEqual(service.player.rate, 0, "Duplicate route notifications must not undo a user pause")
        service.handleExternalPlaybackChange(false)
        service.handleExternalPlaybackChange(true)
        XCTAssertEqual(service.player.rate, 1)
    }
    func testSpaceTogglesPlaybackButPreservesTextEditing() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Video", withExtension: "mp4"))
        let service = PlaybackService(library: LibraryStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { service.shutdown() }
        service.player.allowsExternalPlayback = false
        service.open(source)
        let deadline = Date().addingTimeInterval(10)
        while service.player.currentItem?.status != .readyToPlay && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        let coordinator = KeyboardControls.Coordinator(playback: service, skip: 10)
        coordinator.view = view; coordinator.install()
        defer { coordinator.remove(); window.close() }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        XCTAssertNil(coordinator.handle(event))
        XCTAssertEqual(service.player.rate, 1)
        let returned = coordinator.handle(event)
        if let returned { NSApp.sendEvent(returned) }
        XCTAssertEqual(service.player.rate, 0)
        let editor = NSTextView(frame: view.bounds); editor.isEditable = true
        view.addSubview(editor); window.makeFirstResponder(editor)
        XCTAssertNotNil(coordinator.handle(event))
        NSApp.sendEvent(event)
        XCTAssertEqual(service.player.rate, 0)
        XCTAssertEqual(editor.string, " ")
    }
    func testMultichannelAudioTracksAndManifestChannels() async throws {
        var tracks = StreamTracks()
        tracks.audio = [
            StreamAudioTrack(index: 0, name: "English 5.1", language: "en", channels: 6, described: false),
            StreamAudioTrack(index: 1, name: "Spanish 7.1", language: "es", channels: 8, described: false),
            StreamAudioTrack(index: 2, name: "Commentary Stereo", language: "en", channels: 2, described: false)
        ]
        let manifest = String(decoding: tracks.master(), as: UTF8.self)
        XCTAssertTrue(manifest.contains("NAME=\"English 5.1\",LANGUAGE=\"en\",AUTOSELECT=YES,DEFAULT=YES,CHANNELS=\"6\""))
        XCTAssertTrue(manifest.contains("NAME=\"Spanish 7.1\",LANGUAGE=\"es\",AUTOSELECT=YES,DEFAULT=NO,CHANNELS=\"8\""))
        XCTAssertTrue(manifest.contains("NAME=\"Commentary Stereo\",LANGUAGE=\"en\",AUTOSELECT=YES,DEFAULT=NO,CHANNELS=\"2\""))
    }
}
