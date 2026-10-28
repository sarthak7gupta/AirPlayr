import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Application-level actions: open panels, library import, export, and subtitle folder grants.
@MainActor @Observable final class AppState {
    var library: LibraryStore
    var playback: PlaybackService
    let exporter = CompatibleExportService()
    var showingSettings = false
    var showingLicenses = false
    init() { let library = LibraryStore(); self.library = library; playback = PlaybackService(library: library) }
    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MediaPolicy.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Open Media"
        panel.begin { response in
            if response == .OK { self.importFiles(panel.urls) }
        }
    }
    func enqueueFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MediaPolicy.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add to Queue"
        panel.begin { response in
            if response == .OK {
                let expanded = PlaybackService.expandMediaURLs(panel.urls)
                for url in expanded {
                    let access = FileAccess(url)
                    defer { withExtendedLifetime(access) {} }
                    _ = try? self.library.remember(url)
                }
                self.playback.enqueue(panel.urls)
            }
        }
    }
    func importFiles(_ urls: [URL]) {
        let expanded = PlaybackService.expandMediaURLs(urls)
        let list = expanded.isEmpty ? urls : expanded
        for url in list.dropFirst() {
            let access = FileAccess(url)
            defer { withExtendedLifetime(access) {} }
            do { _ = try library.remember(url) } catch { library.issue = error.localizedDescription }
        }
        if list.count > 1 {
            playback.openFiles(list)
        } else if let first = list.first {
            playback.open(first)
        }
    }
    func open(_ entry: MediaEntry) {
        do {
            let resumePos = playback.resumePlaybackEnabled ? entry.position : 0
            playback.open(try library.resolve(entry), resume: resumePos)
        } catch { playback.issue = MediaIssue.unreadable.localizedDescription }
    }
    func openFromBeginning(_ entry: MediaEntry) {
        do {
            library.resetProgress(entry.id)
            playback.open(try library.resolve(entry), resume: 0)
        } catch { playback.issue = MediaIssue.unreadable.localizedDescription }
    }
    func revealInFinder(_ entry: MediaEntry) {
        guard let url = try? library.resolve(entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func clearTemporaryStreamCache() {
        TemporaryCacheCleanup.removeAbandonedCaches()
    }
    func exportCompatibleCopy() {
        guard let source = playback.sourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " - TV.mp4"
        panel.message = "Create a new H.264/AAC copy, up to 720p at 30 fps. Uses the first audio track. Loaded SRT subtitles are permanently burned in; embedded subtitle tracks are not copied. Conversion takes time and extra disk space."
        panel.prompt = "Export Copy"
        let subtitles = playback.externalSubtitles
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            self.exporter.start(source: source, destination: destination, subtitles: subtitles, appearance: self.playback.subtitleAppearance)
        }
    }
    func allowSubtitleFolder() {
        guard let source = playback.sourceURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = source.deletingLastPathComponent()
        panel.message = "Allow automatic loading of the matching SRT beside this movie. AirPlayr only checks the exact matching filename."
        panel.prompt = "Allow Folder"
        panel.begin { response in
            if response == .OK, let folder = panel.url { self.playback.allowSubtitleFolder(folder) }
        }
    }
    func openSubtitles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.prompt = "Load Subtitles"
        panel.begin { response in if response == .OK, let url = panel.url { self.playback.loadSubtitles(url) } }
    }
}

@MainActor final class AirPlayrAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        TemporaryCacheCleanup.removeAbandonedCaches()
        if let url = Bundle.main.url(forResource: "AirPlayrIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
}

/// SwiftUI entry point: main player window, settings, menus, and FFmpeg license sheet.
@main struct AirPlayrApp: App {
    @NSApplicationDelegateAdaptor(AirPlayrAppDelegate.self) private var delegate
    @State private var state = AppState()
    @AppStorage("skipInterval") private var skipInterval = 10.0
    var body: some Scene {
        Window("AirPlayr", id: "main") {
            MainView(state: state)
                .preferredColorScheme(.dark)
                .sheet(isPresented: $state.showingLicenses) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Open Source Licenses").font(.title2)
                        ScrollView { Text(licenseText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        HStack { Spacer(); Button("Done") { state.showingLicenses = false }.keyboardShortcut(.defaultAction) }
                    }.padding(24).frame(width: 620, height: 480)
                }
                .frame(minWidth: 800, minHeight: 530)
                .onOpenURL { state.importFiles([$0]) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in state.exporter.cancel(); state.playback.shutdown() }
                .onDisappear { state.playback.stop() }
        }
        .defaultSize(width: 1060, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Open File…", action: state.openFiles).keyboardShortcut("o") }
            CommandGroup(after: .help) { Button("Open Source Licenses…") { state.showingLicenses = true } }
            CommandMenu("Playback") {
                Button("Play / Pause (Space)", action: state.playback.togglePlayback)
                    .disabled(state.playback.player.currentItem == nil)
                Button("Previous in Queue", action: state.playback.playPrevious)
                    .keyboardShortcut("[", modifiers: [.command])
                    .disabled(!state.playback.canPlayPrevious)
                Button("Next in Queue", action: state.playback.playNext)
                    .keyboardShortcut("]", modifiers: [.command])
                    .disabled(!state.playback.canPlayNext)
                Button("Add Files to Queue…", action: state.enqueueFiles)
                Divider()
                Button("Skip Backward (←)") { if !(NSApp.keyWindow?.firstResponder is NSTextView) { state.playback.skip(-skipInterval) } }
                Button("Skip Forward (→)") { if !(NSApp.keyWindow?.firstResponder is NSTextView) { state.playback.skip(skipInterval) } }
                Button("Volume Up (↑)") { state.playback.adjustVolume(0.05) }
                Button("Volume Down (↓)") { state.playback.adjustVolume(-0.05) }
                Button("Mute / Unmute (M)", action: state.playback.toggleMute)
                Divider()
                Menu("Playback Speed") {
                    Button("Increase Speed by 0.25×") { state.playback.stepPlaybackRate(increase: true) }
                        .disabled(state.playback.playbackRate >= PlaybackService.maximumPlaybackRate)
                    Button("Decrease Speed by 0.25×") { state.playback.stepPlaybackRate(increase: false) }
                        .disabled(state.playback.playbackRate <= PlaybackService.minimumPlaybackRate)
                    Divider()
                    ForEach(PlaybackService.playbackRates, id: \.self) { rate in
                        Button((state.playback.playbackRate == rate ? "✓ " : "") + String(format: "%g×", rate)) { state.playback.setPlaybackRate(rate) }
                    }
                }
                Menu("Subtitle Sync Offset") {
                    Button("Subtitle Earlier (-0.25s)") { state.playback.adjustSubtitleOffset(by: -0.25) }
                    Button("Subtitle Later (+0.25s)") { state.playback.adjustSubtitleOffset(by: 0.25) }
                    Button("Reset Subtitle Offset (\(String(format: "%+.2fs", state.playback.subtitleOffsetSeconds)))") { state.playback.resetSubtitleOffset() }
                        .disabled(state.playback.subtitleOffsetSeconds == 0)
                }
                Button("Load External Subtitles…", action: state.openSubtitles).keyboardShortcut("s", modifiers: [.command, .shift]).disabled(state.playback.player.currentItem == nil)
                Button("Prepare for TV", action: state.playback.prepareForTV).disabled(state.playback.sourceURL == nil || state.playback.isPreparingForTV || state.playback.dimensions == nil)
                Button("Export TV-Compatible Copy…", action: state.exportCompatibleCopy).disabled(state.playback.sourceURL == nil || state.exporter.isExporting || state.playback.sourceURL.map(MKVBridge.requiresBridge) == true)
                Toggle("Prevent Mac from Sleeping While Playing", isOn: Binding(get: { state.playback.preventSleepWhilePlaying }, set: { state.playback.setPreventSleepWhilePlaying($0) }))
                Button("Stop Playback", action: state.playback.stop).keyboardShortcut(".")
                Button("Enter / Exit Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.command, .control])
            }
        }
        Settings {
            AirPlayrSettingsView(state: state, isSheet: false)
        }
    }
    private var licenseText: String {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("FFmpegLicenses") else { return "FFmpeg 9.0.2 — LGPL 2.1 or later." }
        return ["NOTICE.txt", "COPYING.LGPLv2.1", "LICENSE.md"].compactMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n\n")
    }
}
