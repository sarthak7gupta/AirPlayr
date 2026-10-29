import SwiftUI
import AVKit
import UniformTypeIdentifiers

// MARK: - AppKit bridges and primary window

/// Chromeless `AVPlayerView` used for local preview; AirPlay routing uses `AVRoutePickerView`.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
struct AirPlayPicker: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        view.setAccessibilityLabel("Choose AirPlay destination")
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) { view.player = player }
}

/// Primary window: library sidebar, player surface, timeline, and AirPlay/Cast route pickers.
@MainActor
struct MainView: View {
    @State private var showingSubtitleAppearance = false
    @State private var showingCastConnect = false
    @State private var showingOpenSubtitles = false
    @State private var isUpNextExpanded = true
    @State private var isLibraryExpanded = true
    @Bindable var state: AppState
    @AppStorage("skipInterval") private var skipInterval = 10.0
    @State private var search = ""
    @State private var showLibrary = true
    private enum Focus { case search, player }
    @FocusState private var focus: Focus?
    var body: some View {
        HStack(spacing: 0) {
            if showLibrary {
                sidebarPane
                Divider()
            }
            VStack(spacing: 0) {
                if state.playback.phase == .empty {
                    VStack(spacing: 18) {
                        Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.secondary)
                        Text("Your movies. A bigger screen.").font(.title2.weight(.medium))
                        Text("Open a movie or audio file, then choose an AirPlay, Chromecast, or DLNA destination.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            Button("Open Media…", systemImage: "plus", action: state.openFiles).buttonStyle(.borderedProminent).controlSize(.large)
                            Button("Add to Queue…", systemImage: "text.badge.plus", action: state.enqueueFiles).controlSize(.large)
                        }
                        Text("Or drop files or folders here").font(.caption).foregroundStyle(.tertiary)
                    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZStack(alignment: .bottom) {
                        Color.black
                        PlayerSurface(player: state.playback.player)
                            .focusable().focused($focus, equals: .player)
                            .onTapGesture { focus = .player }
                        if let artwork = state.playback.artwork, state.playback.dimensions == nil {
                            Image(nsImage: artwork).resizable().scaledToFit().padding(45)
                        }
                        if !state.playback.subtitleText.isEmpty && !state.playback.externalPlayback && !state.playback.isCompatibilityStreaming {
                            SubtitleOverlay(text: state.playback.subtitleText, style: state.playback.subtitleAppearance)
                        }
                        if state.playback.phase == .loading || state.playback.phase == .waiting || state.playback.phase == .seeking {
                            ProgressView().padding(20).frame(maxHeight: .infinity)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    controls
                }
                if let message = state.exporter.message {
                    HStack(spacing: 12) {
                        if state.exporter.isExporting { ProgressView().controlSize(.small) }
                        Text(message).font(.callout)
                        Spacer()
                        if state.exporter.isExporting { Button("Cancel", action: state.exporter.cancel) }
                        if let output = state.exporter.output { Button("Open Copy") { state.playback.open(output); state.exporter.message = nil } }
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                state.exporter.message = nil
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss message")
                        .accessibilityLabel("Dismiss message")
                    }.padding(14).background(.blue.opacity(0.08))
                }
                if let issue = state.playback.issue ?? state.library.issue {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue).font(.callout).textSelection(.enabled)
                            if let code = state.playback.diagnosticCode { Text(code).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                        if state.playback.phase == .failed {
                            Button("Retry", action: state.playback.retry)
                            Button("Export Copy…", action: state.exportCompatibleCopy).disabled(state.exporter.isExporting || state.playback.sourceURL == nil || state.playback.sourceURL.map(MKVBridge.requiresBridge) == true)
                        }
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                state.playback.issue = nil
                                state.library.issue = nil
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss error")
                        .accessibilityLabel("Dismiss error")
                    }.padding(14).background(.orange.opacity(0.12))
                }
            }
        }
        .background(KeyboardControls(playback: state.playback, skipInterval: skipInterval).frame(width: 0, height: 0))
        .onChange(of: state.playback.sourceURL) { _, _ in focus = .player }
        .onChange(of: state.playback.phase) { _, phase in if phase == .loading { focus = .player } }
        .navigationTitle(state.playback.title)
        .sheet(isPresented: $showingSubtitleAppearance) {
            SubtitleAppearanceEditor(style: state.playback.subtitleAppearance, streaming: state.playback.isCompatibilityStreaming, apply: state.playback.setSubtitleAppearance)
        }
        .sheet(isPresented: $showingCastConnect) {
            CastConnectSheet(playback: state.playback)
        }
        .sheet(isPresented: $showingOpenSubtitles) {
            OpenSubtitlesSheet(playback: state.playback)
        }
        .sheet(isPresented: $state.showingSettings) {
            AirPlayrSettingsView(state: state, isSheet: true, onCustomizeSubtitles: {
                state.showingSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { showingSubtitleAppearance = true }
            })
        }
        .onAppear { state.playback.cast.startDiscovery() }
        .onChange(of: state.playback.title) { _, _ in NSApp.mainWindow?.makeFirstResponder(nil) }
        .toolbar {
            ToolbarItem(placement: .navigation) { Button { showLibrary.toggle() } label: { Image(systemName: "sidebar.left") }.help("Show or hide library") }
            ToolbarItem { Button(action: state.openFiles) { Image(systemName: "folder.badge.plus") }.help("Open media (⌘O)") }
            ToolbarItem { AirPlayPicker(player: state.playback.player).frame(width: 36, height: 28).help("Choose an AirPlay destination. Select this Mac to disconnect.") }
            ToolbarItem { castMenu }
            ToolbarItem {
                Button { state.showingSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Open AirPlayr Settings (⌘,)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            state.importFiles(files); return true
        }
    }

    private var sidebarPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SidebarBrand()
                Spacer(minLength: 0)
                if state.library.isPrivateMode {
                    Text("PRIVATE")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.purple.opacity(0.22))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                        .help("Private Mode is active: newly opened files are not saved to Recents.")
                }
            }

            // Collapsible Up Next Queue Section
            if !state.playback.queue.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { isUpNextExpanded.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isUpNextExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Text("Up Next")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(state.playback.queueIndex + 1)/\(state.playback.queue.count)")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.secondary.opacity(0.16))
                                    .clipShape(Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(action: state.enqueueFiles) {
                            Image(systemName: "plus")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Add files or folder to Up Next Queue")
                        Button("Clear") { state.playback.clearQueue() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Clear Up Next Queue")
                    }
                    if isUpNextExpanded {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(state.playback.queue.enumerated()), id: \.offset) { index, url in
                                    HStack(spacing: 6) {
                                        Button {
                                            focus = .player
                                            state.playback.playQueueItem(at: index)
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: index == state.playback.queueIndex ? "speaker.wave.2.fill" : "film")
                                                    .font(.caption)
                                                    .foregroundStyle(index == state.playback.queueIndex ? Color.accentColor : .secondary)
                                                Text(url.deletingPathExtension().lastPathComponent)
                                                    .font(.caption.weight(index == state.playback.queueIndex ? .semibold : .regular))
                                                    .lineLimit(1)
                                                Spacer(minLength: 0)
                                            }
                                        }.buttonStyle(.plain)
                                        Button {
                                            state.playback.removeFromQueue(at: index)
                                        } label: {
                                            Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                                        }.buttonStyle(.plain).help("Remove from queue")
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(index == state.playback.queueIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }.frame(maxHeight: 135)
                    }
                }
                Divider()
            }

            // Collapsible Library Section Header with Inline Actions
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isLibraryExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isLibraryExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text("Library").font(.headline.weight(.semibold))
                        if !state.library.entries.isEmpty {
                            Text("\(state.library.entries.count)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.16))
                                .clipShape(Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Open Files or Folder… (⌘O)", systemImage: "play.rectangle.on.rectangle", action: state.openFiles)
                    Button("Add Files to Up Next Queue…", systemImage: "text.badge.plus", action: state.enqueueFiles)
                    if !state.library.entries.isEmpty {
                        Divider()
                        Button("Enqueue All Recent Items") {
                            let urls = state.library.entries.compactMap { try? state.library.resolve($0) }
                            if !urls.isEmpty { state.playback.enqueue(urls) }
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add media to Library or Up Next Queue")

                if !state.library.entries.isEmpty {
                    Button {
                        state.library.clear()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all recent items from Library")
                }
            }

            if isLibraryExpanded {
                TextField("Search recent media", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .search)
                if state.library.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.library.isPrivateMode ? "Private Mode is enabled." : "Your recently opened movies and music will appear here.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        if state.library.isPrivateMode {
                            Button("Turn Off Private Mode") { state.library.isPrivateMode = false }
                                .font(.caption)
                                .buttonStyle(.link)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List {
                        ForEach(state.library.entries.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { entry in
                            LibraryEntryRow(
                                entry: entry,
                                isCurrent: state.playback.title == entry.title && state.playback.phase != .empty,
                                onOpen: { focus = .player; state.open(entry) },
                                onOpenFromBeginning: { focus = .player; state.openFromBeginning(entry) },
                                onEnqueue: {
                                    if let url = try? state.library.resolve(entry) {
                                        state.playback.enqueue([url])
                                    }
                                },
                                onResetProgress: { state.library.resetProgress(entry.id) },
                                onRevealInFinder: { state.revealInFinder(entry) },
                                onRemove: { state.library.remove(entry.id) }
                            )
                        }
                    }.listStyle(.plain)
                }
            } else {
                Spacer()
            }

            Divider()

            // Compact Sidebar Footer Toolbar (+ Add Media, + Queue, ⚙ Settings)
            HStack(spacing: 8) {
                Menu {
                    Button("Open Files or Folder… (⌘O)", systemImage: "folder.badge.plus", action: state.openFiles)
                    Button("Add Files to Up Next Queue…", systemImage: "text.badge.plus", action: state.enqueueFiles)
                } label: {
                    Label("Add Media", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                } primaryAction: {
                    state.openFiles()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("Open media file(s) or click arrow for queue options")

                Button(action: state.enqueueFiles) {
                    Image(systemName: "text.badge.plus")
                }
                .buttonStyle(.bordered)
                .help("Add files or folder to Up Next Queue")

                Button {
                    state.showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .help("Open AirPlayr Settings (⌘,)")
            }
        }
        .padding(16)
        .frame(width: 244)
        .background(.bar)
    }
    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.playback.title).font(.headline).lineLimit(1)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { state.playback.stepPlaybackRate(increase: false) } label: { Image(systemName: "minus") }
                    .disabled(state.playback.playbackRate <= PlaybackService.minimumPlaybackRate)
                    .accessibilityLabel("Decrease playback speed by 0.25×").help("Slower by 0.25×")
                Menu {
                    ForEach(PlaybackService.playbackRates, id: \.self) { rate in
                        Button((state.playback.playbackRate == rate ? "✓ " : "") + String(format: "%g×", rate)) { state.playback.setPlaybackRate(rate) }
                    }
                } label: { Text(String(format: "%g×", state.playback.playbackRate)).monospacedDigit() }
                    .help("Playback speed. TV support varies by receiver.")
                Button { state.playback.stepPlaybackRate(increase: true) } label: { Image(systemName: "plus") }
                    .disabled(state.playback.playbackRate >= PlaybackService.maximumPlaybackRate)
                    .accessibilityLabel("Increase playback speed by 0.25×").help("Faster by 0.25×")
                trackMenu
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Full screen (⌃⌘F)")
            }
            Timeline(playback: state.playback)
            HStack(spacing: 20) {
                Spacer()
                Button(action: state.playback.playPrevious) { Image(systemName: "backward.end.fill") }
                    .disabled(!state.playback.canPlayPrevious)
                    .help("Previous in queue (⌘[)")
                Button { state.playback.skip(-skipInterval) } label: { Image(systemName: "gobackward"); Text("\(Int(skipInterval))s") }.help("Skip backward (←)")
                Button(action: state.playback.togglePlayback) {
                    Image(systemName: state.playback.player.timeControlStatus == .paused ? "play.fill" : "pause.fill").font(.title2).frame(width: 30)
                }.accessibilityLabel("Play or pause").help("Play or pause (Space)")
                Button { state.playback.skip(skipInterval) } label: { Text("\(Int(skipInterval))s"); Image(systemName: "goforward") }.help("Skip forward (→)")
                Button(action: state.playback.playNext) { Image(systemName: "forward.end.fill") }
                    .disabled(!state.playback.canPlayNext)
                    .help("Next in queue (⌘])")
                Spacer()
                Button(action: state.playback.toggleMute) { Image(systemName: state.playback.isMuted ? "speaker.slash" : "speaker.wave.2") }.help("Mute / unmute (M)").accessibilityLabel(state.playback.isMuted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { state.playback.volume }, set: { state.playback.volume = $0 }), in: 0...1).frame(width: 90).accessibilityLabel("Player volume").help("Receiver volume may need its own remote")
            }.buttonStyle(.plain).disabled(state.playback.player.currentItem == nil)
            if let name = state.playback.externalSubtitleName {
                Text("\(name) • " + (state.playback.burnSubtitlesForTV ? "TV burn-in enabled; change captions on this Mac." : "Selectable TV subtitles use the receiver’s styling."))
                    .font(.caption).foregroundStyle(state.playback.externalPlayback ? .orange : .secondary)
            }
            if let routeMessage = state.playback.routeMessage { Text(routeMessage).font(.caption).foregroundStyle(.secondary) }
            if let castStatus = state.playback.cast.statusMessage { Text(castStatus).font(.caption).foregroundStyle(.cyan) }
        }.padding(20).background(.bar)
    }
    private var status: String {
        let output = state.playback.cast.activeDevice.map { "Casting to \($0.name)" } ?? (state.playback.externalPlayback ? "External video route active" : "Mac playback • check AirPlay or Cast for TV output")
        let speed = state.playback.actualPlaybackRate > 0 && state.playback.actualPlaybackRate != 1 ? String(format: " · %g×", state.playback.actualPlaybackRate) : ""
        return "\(state.playback.phase.rawValue) · \(output)" + (state.playback.dimensions.map { " · \($0)" } ?? "") + speed
    }
    private var castMenu: some View {
        Menu {
            Section("Chromecast & Miracast / DLNA") {
                if state.playback.cast.devices.isEmpty {
                    Text("Searching local network for Chromecast & DLNA TVs…")
                } else {
                    ForEach(state.playback.cast.devices) { device in
                        Button {
                            state.playback.startCasting(to: device)
                        } label: {
                            Text((state.playback.cast.activeDevice?.id == device.id ? "✓ " : "") + "\(device.name) (\(device.model))")
                        }.disabled(state.playback.sourceURL == nil)
                    }
                }
                if state.playback.cast.activeDevice != nil {
                    Button("Disconnect Cast Receiver", role: .destructive) { state.playback.stopCasting() }
                }
                Divider()
                Button("Connect to Cast / Miracast by IP…") { showingCastConnect = true }
                Button("Open macOS Wireless Display Settings…") { state.playback.cast.openSystemMirroringSettings() }
            }
        } label: {
            Image(systemName: state.playback.cast.activeDevice == nil ? "tv.badge.wifi" : "tv.badge.wifi.fill")
        }.help("Stream to Chromecast or Miracast / DLNA receivers")
    }
    private var trackMenu: some View {
        Menu {
            Section("Subtitles") {
                Button("Off") { state.playback.selectSubtitle(nil) }
                if let group = state.playback.subtitleGroup {
                    ForEach(Array(group.options.enumerated()), id: \.offset) { _, option in
                        Button { state.playback.selectSubtitle(option) } label: {
                            Text((state.playback.subtitleSelection == option ? "✓ " : "") + trackLabel(option))
                        }.disabled(!option.isPlayable)
                    }
                } else { Text("No selectable embedded subtitles") }
                Button("Load External SRT…", action: state.openSubtitles)
                Button("Search OpenSubtitles…") { showingOpenSubtitles = true }
                Button("Allow Subtitle Folder…", action: state.allowSubtitleFolder)
                Button("Subtitle Display…") { showingSubtitleAppearance = true }
                Menu("Subtitle Sync (\(String(format: "%+.2fs", state.playback.subtitleOffsetSeconds)))") {
                    Button("Earlier (-0.25s)") { state.playback.adjustSubtitleOffset(by: -0.25) }
                    Button("Later (+0.25s)") { state.playback.adjustSubtitleOffset(by: 0.25) }
                    Button("Reset (0.00s)") { state.playback.resetSubtitleOffset() }
                        .disabled(state.playback.subtitleOffsetSeconds == 0)
                }
                Toggle("Burn External SRT into TV Video", isOn: Binding(get: { state.playback.burnSubtitlesForTV }, set: { state.playback.setBurnSubtitlesForTV($0) }))
                Text("TV subtitle styling uses the receiver’s settings. Burn-in keeps Mac styling but cannot be switched off on the TV.")
            }
            if let group = state.playback.audioGroup {
                Section("Audio") {
                    ForEach(Array(group.options.enumerated()), id: \.offset) { _, option in
                        Button { state.playback.selectAudio(option) } label: { Text((state.playback.audioSelection == option ? "✓ " : "") + trackLabel(option)) }.disabled(!option.isPlayable)
                    }
                }
            }
        } label: { Image(systemName: "captions.bubble") }.help("Subtitles and audio tracks").disabled(state.playback.player.currentItem == nil)
    }
    private func trackLabel(_ option: AVMediaSelectionOption) -> String {
        var label = option.displayName
        if let language = option.extendedLanguageTag { label += " (\(language))" }
        if option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) { label += " · SDH" }
        if option.hasMediaCharacteristic(.describesVideoForAccessibility) { label += " · Audio description" }
        if !option.isPlayable { label += " · Unsupported" }
        return label
    }
}

struct Timeline: View {
    let playback: PlaybackService
    @State private var preview: Double?
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let duration = playback.duration ?? 0
                let fraction = duration > 0 ? min(1, max(0, (preview ?? playback.position) / duration)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.2)).frame(height: 4)
                    Capsule().fill(Color.accentColor).frame(width: geometry.size.width * fraction, height: 4)
                    Circle().fill(Color.accentColor).frame(width: 12, height: 12).offset(x: max(0, (geometry.size.width - 12) * fraction))
                }.frame(height: 22).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0, geometry.size.width > 0 else { return }
                            preview = min(1, max(0, value.location.x / geometry.size.width)) * duration
                        }
                        .onEnded { value in
                            guard duration > 0, geometry.size.width > 0 else { preview = nil; return }
                            playback.seek(to: min(1, max(0, value.location.x / geometry.size.width)) * duration)
                            preview = nil
                        })
                    .accessibilityElement().accessibilityLabel("Playback timeline")
                    .accessibilityValue("\(MediaPolicy.time(preview ?? playback.position)) of \(MediaPolicy.time(playback.duration ?? .nan))")
                    .accessibilityAdjustableAction { direction in playback.skip(direction == .increment ? 10 : -10) }
            }.frame(height: 22)
            HStack {
                Text(MediaPolicy.time(preview ?? playback.position))
                Spacer()
                Text(MediaPolicy.time(playback.duration ?? .nan))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.onChange(of: playback.title) { _, _ in preview = nil }
    }
}

/// Native text inherits the system appearance; the supplied mark has real alpha transparency.
/// Native wordmark matching [docs/BRANDING.md](../../docs/BRANDING.md): asset mark + SF “airplay” + gradient “r”.
struct SidebarBrand: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("BrandMark")
                .resizable().scaledToFit().frame(width: 48, height: 48)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: -0.4) {
                Text("AIRPLAY").foregroundStyle(.primary).tracking(-0.6)
                Text("R").bold().foregroundStyle(LinearGradient(colors: [Color(red: 0, green: 0.88, blue: 1), Color(red: 0.04, green: 0.18, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }.font(.system(size: 26, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AirPlayr")
    }
}

@MainActor
struct CastConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let playback: PlaybackService
    @State private var name = ""
    @State private var host = ""
    @State private var port = "8009"
    @State private var kind: CastReceiverKind = .chromecast
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Cast / Miracast Receiver").font(.title2.weight(.semibold))
            Form {
                Picker("Protocol", selection: $kind) {
                    ForEach(CastReceiverKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: kind) { _, newValue in port = newValue == .chromecast ? "8009" : "1400" }
                TextField("Receiver Name (optional)", text: $name)
                TextField("IP Address or Hostname (e.g. 192.168.1.50)", text: $host)
                TextField("Port", text: $port)
            }
            Text("Chromecast uses TLS on port 8009. Miracast/DLNA network renderers use UPnP AVTransport over HTTP. For hardware Wi-Fi Direct Miracast display sinks, you can also use macOS Display Mirroring.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add & Connect") {
                    let device = playback.cast.addManualDevice(name: name, host: host, port: UInt16(port), kind: kind)
                    if playback.sourceURL != nil { playback.startCasting(to: device) }
                    dismiss()
                }
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440)
    }
}

@MainActor
struct OpenSubtitlesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let playback: PlaybackService
    @State private var apiKey = OpenSubtitlesService.loadAPIKey()
    @State private var query = ""
    @State private var language = "en"
    @State private var results: [OpenSubtitlesResult] = []
    @State private var isSearching = false
    @State private var isDownloadingID: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Opt-In OpenSubtitles Search").font(.title2.weight(.semibold))
            Text("AirPlayr makes zero network requests unless you click Search below. Your API key is stored locally in the macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                SecureField("OpenSubtitles API Key", text: $apiKey)
                    .onChange(of: apiKey) { _, newValue in OpenSubtitlesService.saveAPIKey(newValue) }
                TextField("Movie / Episode Query", text: $query)
                TextField("Language Code (e.g. en, es, fr)", text: $language)
            }
            HStack {
                if let url = playback.sourceURL, let hash = try? OpenSubtitlesService.computeMovieHash(for: url) {
                    Text("Movie Hash: \(hash)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(isSearching ? "Searching…" : "Search OpenSubtitles") {
                    runSearch()
                }
                .disabled(isSearching || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
            }
            List(results) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.release).font(.callout.weight(.medium)).lineLimit(1)
                            if item.hashMatch {
                                Text("HASH MATCH").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1).background(.green.opacity(0.2)).cornerRadius(4)
                            }
                        }
                        Text("\(item.language.uppercased()) • \(item.downloadCount) downloads • \(item.fileName)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(isDownloadingID == item.id ? "Downloading…" : "Download & Use") {
                        download(item)
                    }
                    .disabled(isDownloadingID != nil)
                }
            }.frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 540, height: 460)
        .onAppear {
            if query.isEmpty { query = playback.title }
            if !playback.preferredSubtitleLanguage.isEmpty { language = playback.preferredSubtitleLanguage }
        }
    }

    private func runSearch() {
        isSearching = true
        errorMessage = nil
        Task {
            do {
                let found = try await OpenSubtitlesService.search(videoURL: playback.sourceURL, query: query, language: language, apiKey: apiKey)
                await MainActor.run {
                    results = found
                    isSearching = false
                    if found.isEmpty { errorMessage = "No matching subtitles found." }
                }
            } catch {
                await MainActor.run {
                    isSearching = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func download(_ item: OpenSubtitlesResult) {
        isDownloadingID = item.id
        errorMessage = nil
        Task {
            do {
                let (savedURL, document) = try await OpenSubtitlesService.download(fileID: item.fileID, apiKey: apiKey, near: playback.sourceURL)
                await MainActor.run {
                    isDownloadingID = nil
                    playback.applyDownloadedSubtitles(url: savedURL, document: document)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isDownloadingID = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct LibraryEntryRow: View {
    let entry: MediaEntry
    let isCurrent: Bool
    let onOpen: () -> Void
    let onOpenFromBeginning: () -> Void
    let onEnqueue: () -> Void
    let onResetProgress: () -> Void
    let onRevealInFinder: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    private var progressFraction: Double {
        guard entry.position > 0, let duration = entry.duration, duration > 0 else { return 0 }
        return min(1.0, max(0.0, entry.position / duration))
    }

    private var subtitleText: String {
        if entry.position > 0 {
            if let duration = entry.duration, duration > 0 {
                return "Continue at \(MediaPolicy.time(entry.position)) / \(MediaPolicy.time(duration))"
            }
            return "Continue at \(MediaPolicy.time(entry.position))"
        }
        return "Ready to play"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.rectangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.callout.weight(isCurrent ? .semibold : .regular))
                            .lineLimit(1)
                        Text(subtitleText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if entry.position > 0 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(.secondary.opacity(0.2))
                                        .frame(height: 3)
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(width: max(6, geo.size.width * (progressFraction > 0 ? progressFraction : 0.35)), height: 3)
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered {
                HStack(spacing: 4) {
                    Button(action: onEnqueue) {
                        Image(systemName: "text.badge.plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Add to Up Next Queue")

                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Recents")
                }
            }
        }
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Play", action: onOpen)
            if entry.position > 0 {
                Button("Play from Beginning", action: onOpenFromBeginning)
                Button("Mark as Unwatched", action: onResetProgress)
            }
            Button("Add to Up Next Queue", action: onEnqueue)
            Divider()
            Button("Reveal in Finder", action: onRevealInFinder)
            Divider()
            Button("Remove from Recents", role: .destructive, action: onRemove)
        }
    }
}

@MainActor
struct AirPlayrSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: AppState
    var isSheet: Bool = false
    var onCustomizeSubtitles: (() -> Void)? = nil

    @AppStorage("skipInterval") private var skipInterval = 10.0
    @State private var openSubtitlesKey = OpenSubtitlesService.loadAPIKey()
    @State private var cacheClearedNotice = false

    var body: some View {
        VStack(spacing: 0) {
            if isSheet {
                HStack {
                    Label("AirPlayr Settings", systemImage: "gearshape.fill")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
                Divider()
            }

            TabView {
                playbackTab
                    .tabItem { Label("Playback", systemImage: "play.circle.fill") }

                audioSubtitlesTab
                    .tabItem { Label("Audio & Subtitles", systemImage: "captions.bubble.fill") }

                tvStreamingTab
                    .tabItem { Label("TV & Streaming", systemImage: "tv.and.mediabox.fill") }

                privacyLibraryTab
                    .tabItem { Label("Privacy & Library", systemImage: "lock.shield.fill") }
            }
            .padding(20)
        }
        .frame(width: 560, height: isSheet ? 440 : 390)
    }

    private var playbackTab: some View {
        Form {
            Section("Timeline & Queue") {
                Picker("Skip interval (← / →)", selection: $skipInterval) {
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                }
                Picker("Current playback speed", selection: Binding(
                    get: { state.playback.playbackRate },
                    set: { state.playback.setPlaybackRate($0) }
                )) {
                    ForEach(PlaybackService.playbackRates, id: \.self) { rate in
                        Text(String(format: "%g×", rate)).tag(rate)
                    }
                }
                Toggle("Automatically play next item in Up Next Queue", isOn: $state.playback.autoPlayNext)
                Toggle("Resume recent movies from last saved position", isOn: $state.playback.resumePlaybackEnabled)
            }

            Section("Power & Display") {
                Toggle("Prevent Mac from sleeping while media is playing or streaming", isOn: Binding(
                    get: { state.playback.preventSleepWhilePlaying },
                    set: { state.playback.setPreventSleepWhilePlaying($0) }
                ))
                HStack {
                    Text("Display sleep lock status")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(state.playback.isPreventingSleep ? "Active (Awake)" : "Idle (Normal Sleep)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.playback.isPreventingSleep ? .green : .secondary)
                }
            }
        }
    }

    private var audioSubtitlesTab: some View {
        Form {
            Section("Preferred Track Languages") {
                TextField("Preferred Audio Language (e.g. en, jpn, es)", text: $state.playback.preferredAudioLanguage)
                TextField("Preferred Subtitle Language (e.g. en, es)", text: $state.playback.preferredSubtitleLanguage)
            }

            Section("Subtitle Timing & TV Styling") {
                HStack {
                    Text("Live Subtitle Sync Offset")
                    Spacer()
                    Button("-0.25s") { state.playback.adjustSubtitleOffset(by: -0.25) }
                    Text(String(format: "%+.2fs", state.playback.subtitleOffsetSeconds))
                        .font(.caption.monospacedDigit())
                        .frame(width: 56)
                    Button("+0.25s") { state.playback.adjustSubtitleOffset(by: 0.25) }
                    Button("Reset") { state.playback.resetSubtitleOffset() }
                        .disabled(state.playback.subtitleOffsetSeconds == 0)
                }
                Toggle("Burn External SRT into TV Video Stream", isOn: Binding(
                    get: { state.playback.burnSubtitlesForTV },
                    set: { state.playback.setBurnSubtitlesForTV($0) }
                ))
                if let onCustomizeSubtitles {
                    Button("Customize Subtitle Display Style…", action: onCustomizeSubtitles)
                }
            }

            Section("Opt-In OpenSubtitles") {
                SecureField("OpenSubtitles API Key (stored in Keychain)", text: $openSubtitlesKey)
                    .onChange(of: openSubtitlesKey) { _, newValue in
                        OpenSubtitlesService.saveAPIKey(newValue)
                    }
                Text("Zero network requests are made unless you explicitly open Search OpenSubtitles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tvStreamingTab: some View {
        Form {
            Section("HLS Delivery & Hardware Encoding") {
                Toggle("Zero-Re-Encode 1080p / 4K Video Passthrough (fMP4 HLS)", isOn: $state.playback.zeroReencodePassthroughEnabled)
                Text("Muxes compressed H.264/HEVC packets directly into fMP4 HLS segments without re-encoding when subtitle burn-in is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Wireless Receiver Discovery (Chromecast & DLNA / Miracast)") {
                Toggle("Automatic UDP SSDP Discovery for DLNA / Miracast TVs", isOn: $state.playback.ssdpDiscoveryEnabled)
                HStack {
                    Text("Discovered LAN Receivers: \(state.playback.cast.devices.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan Local Network") {
                        state.playback.cast.startDiscovery()
                    }
                    Button("Wireless Display Settings…") {
                        state.playback.cast.openSystemMirroringSettings()
                    }
                }
            }

            Section("Temporary Stream Cache") {
                HStack {
                    Button("Clear Temporary Stream Cache") {
                        state.clearTemporaryStreamCache()
                        cacheClearedNotice = true
                    }
                    if cacheClearedNotice {
                        Text("✓ Cache cleared")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private var privacyLibraryTab: some View {
        Form {
            Section("100% Local & Offline Architecture") {
                Text("AirPlayr runs inside the macOS App Sandbox with zero telemetry, zero analytics, and no account required. Media never leaves your local Wi-Fi network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recent Library & Private Mode") {
                Toggle("Private Mode (Do not record newly opened files in Library)", isOn: $state.library.isPrivateMode)
                Picker("Maximum Recent Items", selection: $state.library.maxRecentItems) {
                    Text("25 items").tag(25)
                    Text("50 items").tag(50)
                    Text("100 items").tag(100)
                }
                HStack(spacing: 12) {
                    Button("Clear Recent Library (\(state.library.entries.count))", role: .destructive) {
                        state.library.clear()
                    }
                    .disabled(state.library.entries.isEmpty)

                    Button("Clear Up Next Queue (\(state.playback.queue.count))") {
                        state.playback.clearQueue()
                    }
                    .disabled(state.playback.queue.isEmpty)

                    Spacer()

                    Button("Open Source Licenses…") {
                        if isSheet { dismiss() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            state.showingLicenses = true
                        }
                    }
                }
            }
        }
    }
}
