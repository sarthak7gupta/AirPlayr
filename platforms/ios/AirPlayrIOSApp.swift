#if os(iOS)
import SwiftUI
import AVKit
import MediaPlayer
import UniformTypeIdentifiers

// MARK: - Dual Screen Postures

/// Posture states for adaptive compact, landscape, and split views.
enum DualScreenPosture: String, CaseIterable, Equatable, Sendable {
    case singleScreen = "Single Screen"
    case tabletopHorizontalHinge = "Tabletop (Top Video / Bottom Deck)"
    case bookVerticalHinge = "Split View (Left Video / Right Deck)"
    case externalDisplayExtended = "External Display Extended"

    /// Resolves the optimal layout posture from viewport geometry, hinge rect, and external screen state.
    static func resolve(
        containerSize: CGSize,
        hingeRect: CGRect? = nil,
        hasExternalDisplay: Bool = false
    ) -> DualScreenPosture {
        if hasExternalDisplay {
            return .externalDisplayExtended
        }
        if let hinge = hingeRect, hinge.width > 0 || hinge.height > 0 {
            return hinge.width >= hinge.height ? .tabletopHorizontalHinge : .bookVerticalHinge
        }
        guard containerSize.width > 0, containerSize.height > 0 else { return .singleScreen }
        let ratio = containerSize.width / containerSize.height
        // Split view / wide landscape posture
        if containerSize.width >= 600 && ratio >= 0.85 && ratio <= 1.35 {
            return .bookVerticalHinge
        }
        return .singleScreen
    }
}

// MARK: - Brand Styling Components

struct IOSBrandHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: -0.4) {
                Text("AIRPLAY")
                    .foregroundStyle(.white)
                    .tracking(-0.5)
                Text("R")
                    .bold()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0, green: 0.88, blue: 1), Color(red: 0.15, green: 0.45, blue: 1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .font(.system(size: 21, weight: .bold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AirPlayr for iOS")
    }
}

// MARK: - Local Media Stager (AVFoundation Security-Scope Sandbox Bridge)

/// Bridges security-scoped files selected from UIDocumentPicker / Files to the app container.
/// In iOS, AVPlayer delegates decoding to the out-of-process system daemon `mediaserverd`.
/// Because `mediaserverd` does not inherit external security-scoped permissions, media files
/// must be staged into the app's local sandbox (`tmp/AirPlayr-Staging/`) before playback.
enum IOSMediaStager {
    static let supportedUTTypes: [UTType] = {
        var types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .audio]
        let extensions = ["mp4", "m4v", "mov", "mkv", "m3u8", "ts", "mp3", "m4a", "aac", "flac", "wav"]
        for ext in extensions {
            if let ut = UTType(filenameExtension: ext), !types.contains(ut) {
                types.append(ut)
            }
        }
        return types
    }()

    enum StagingResult {
        case ready(URL)
        case unsupported(String)
        case failed(String)
    }

    static func stage(url: URL) -> StagingResult {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AirPlayr-Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        if url.path.hasPrefix(tempDir.path) || url.path.hasPrefix(Bundle.main.bundlePath) {
            return .ready(url)
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let filename = url.lastPathComponent
        let targetURL = tempDir.appendingPathComponent(filename)

        try? FileManager.default.removeItem(at: targetURL)

        var copyError: Error?
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            do {
                try FileManager.default.copyItem(at: coordinatedURL, to: targetURL)
            } catch {
                copyError = error
            }
        }

        if copyError != nil || coordinatorError != nil {
            // Direct copy fallback if coordinator was rejected
            do {
                try? FileManager.default.removeItem(at: targetURL)
                try FileManager.default.copyItem(at: url, to: targetURL)
            } catch {
                return .failed("Cannot access \(filename): \(copyError?.localizedDescription ?? coordinatorError?.localizedDescription ?? error.localizedDescription)")
            }
        }

        let ext = targetURL.pathExtension.lowercased()
        if ext == "mkv" {
            if let handle = try? FileHandle(forReadingFrom: targetURL) {
                let header = handle.readData(ofLength: 12)
                try? handle.close()
                if header.count >= 8,
                   let ftyp = String(data: header.subdata(in: 4..<8), encoding: .ascii),
                   ftyp == "ftyp" {
                    let mp4URL = targetURL.deletingPathExtension().appendingPathExtension("mp4")
                    try? FileManager.default.removeItem(at: mp4URL)
                    try? FileManager.default.moveItem(at: targetURL, to: mp4URL)
                    return .ready(mp4URL)
                } else if header.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
                    return .unsupported("MKV containers require remuxing. Use MP4, MOV, or M4V on iOS, or stream directly via AirPlay from the Mac app.")
                }
            }
        }
        return .ready(targetURL)
    }
}

// MARK: - Main iOS View

struct AirPlayrIOSView: View {
    @State private var isImportingFiles = false
    @State private var queue: [URL] = []
    @State private var queueIndex: Int = 0
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isSeeking = false
    @State private var seekPreviewTime: Double = 0

    @State private var subtitleAppearance = SubtitleAppearance.load()
    @State private var subtitleOffset: Double = 0.0
    @State private var activeSubtitleText: String = ""
    @State private var errorMessage: String? = nil
    @State private var showingSubtitleSheet = false
    @State private var showingCastSheet = false
    @State private var preventSleep: Bool = true
    @State private var playbackRate: Float = 1.0
    @State private var isMuted: Bool = false
    @State private var volume: Float = 1.0

    @State private var castDevices: [CastReceiverDevice] = []
    @State private var selectedReceiverName: String = "Local iPhone Display"
    @State private var activeAirPlayDeviceName: String? = nil
    @State private var isExternalPlaybackActive: Bool = false
    @State private var activeFileServer: StreamFileServer? = nil
    @State private var simulatedHingeGutter: CGFloat = 12

    private let cyanGradient = LinearGradient(
        colors: [Color(red: 0, green: 0.88, blue: 1), Color(red: 0.15, green: 0.45, blue: 1)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private let deepCinemaBackground = LinearGradient(
        colors: [Color(red: 0.06, green: 0.07, blue: 0.11), Color(red: 0.02, green: 0.02, blue: 0.04)],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        GeometryReader { proxy in
            let externalConnected = UIApplication.shared.openSessions.count > 1
            let posture = DualScreenPosture.resolve(
                containerSize: proxy.size,
                hingeRect: nil,
                hasExternalDisplay: externalConnected
            )

            NavigationStack {
                ZStack(alignment: .bottom) {
                    deepCinemaBackground
                        .ignoresSafeArea()

                    Group {
                        switch posture {
                        case .tabletopHorizontalHinge:
                            VStack(spacing: 0) {
                                videoStage
                                    .frame(height: max(200, (proxy.size.height - simulatedHingeGutter) * 0.48))
                                Color.black.opacity(0.85)
                                    .frame(height: simulatedHingeGutter)
                                    .accessibilityHidden(true)
                                ScrollView {
                                    deckContent(posture: posture)
                                }
                            }
                        case .bookVerticalHinge, .externalDisplayExtended:
                            HStack(spacing: 0) {
                                VStack(spacing: 12) {
                                    videoStage
                                    controlsHUD
                                }
                                .padding(12)
                                .frame(width: max(280, (proxy.size.width - simulatedHingeGutter) * 0.56))

                                Color.black.opacity(0.85)
                                    .frame(width: simulatedHingeGutter)
                                    .accessibilityHidden(true)

                                ScrollView {
                                    deckContent(posture: posture)
                                }
                            }
                        case .singleScreen:
                            ScrollView {
                                VStack(spacing: 16) {
                                    videoStage
                                        .frame(height: min(280, max(210, proxy.size.height * 0.32)))
                                    controlsHUD
                                    wirelessDestinationBento
                                    queueSectionBento
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                .padding(.bottom, 24)
                            }
                        }
                    }

                    if let error = errorMessage {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    errorMessage = nil
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss error")
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(red: 0.16, green: 0.08, blue: 0.06).opacity(0.96))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        IOSBrandHeader()
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            isImportingFiles = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                                .foregroundStyle(.white)
                        }
                        .help("Open Media")

                        Button {
                            showingSubtitleSheet = true
                        } label: {
                            Image(systemName: "captions.bubble")
                                .foregroundStyle(subtitleOffset != 0 ? Color(red: 0, green: 0.88, blue: 1) : .white)
                        }
                        .help("Subtitle Sync & Appearance")

                        IOSAirPlayRoutePicker()
                            .frame(width: 34, height: 34)
                    }
                }
                .fileImporter(
                    isPresented: $isImportingFiles,
                    allowedContentTypes: IOSMediaStager.supportedUTTypes,
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case let .success(urls):
                        if !urls.isEmpty {
                            openQueue(urls)
                        }
                    case let .failure(error):
                        withAnimation { errorMessage = error.localizedDescription }
                    }
                }
                .sheet(isPresented: $showingSubtitleSheet) {
                    IOSSubtitleSettingsSheet(
                        appearance: $subtitleAppearance,
                        offset: $subtitleOffset,
                        previewText: activeSubtitleText
                    )
                }
                .sheet(isPresented: $showingCastSheet) {
                    IOSCastConnectSheet(
                        devices: $castDevices,
                        selectedDevice: $selectedReceiverName
                    )
                }
                .onAppear {
                    setupTimeObserver()
                    setupAudioSessionAndAirPlay()
                    updateConnectedRoute()
                }
                .onReceive(player.publisher(for: \.currentItem?.status)) { status in
                    if status == .failed, let err = player.currentItem?.error {
                        handlePlaybackFailure(err)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
                    if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                        handlePlaybackFailure(error)
                    }
                }
                .onReceive(player.publisher(for: \.isExternalPlaybackActive)) { active in
                    isExternalPlaybackActive = active
                    updateConnectedRoute()
                }
                .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                    updateConnectedRoute()
                }
                .onChange(of: selectedReceiverName) { _, newReceiver in
                    if newReceiver != "Local iPhone Display" && !queue.isEmpty && !isPlaying {
                        player.play()
                        isPlaying = true
                        UIApplication.shared.isIdleTimerDisabled = preventSleep
                    }
                }
            }
        }
    }

    // MARK: - Video Canvas Stage

    private var videoStage: some View {
        ZStack(alignment: .bottom) {
            Color.black

            if queue.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 38))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("No Media Loaded")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Tap Open Media to select video files")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                    Button {
                        isImportingFiles = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.plus")
                            Text("Open Media")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(cyanGradient)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isExternalPlaybackActive {
                ZStack {
                    IOSVideoCanvas(player: player)
                        .opacity(0.01)
                    VStack(spacing: 12) {
                        Image(systemName: "airplayvideo")
                            .font(.system(size: 46))
                            .foregroundStyle(cyanGradient)
                        Text("Streaming to \(activeAirPlayDeviceName ?? "AirPlay TV")")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Video is playing on your TV screen. Use controls below to scrub or pause.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                IOSVideoCanvas(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            // Dark vignette overlay top/bottom
            LinearGradient(
                colors: [Color.black.opacity(0.65), Color.clear, Color.black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .allowsHitTesting(false)

            // Header info overlay inside canvas
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentTitle)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(currentFormatBadge)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(cyanGradient)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                            Text(selectedReceiverName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Circle()
                        .fill(isExternalPlaybackActive ? Color.green : (selectedReceiverName.contains("Local") ? Color.blue : Color.orange))
                        .frame(width: 8, height: 8)
                        .shadow(color: (isExternalPlaybackActive ? Color.green : (selectedReceiverName.contains("Local") ? Color.blue : Color.orange)).opacity(0.8), radius: 4)
                }
                .padding(12)
                .background(.ultraThinMaterial.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.top, 10)

                if activeAirPlayDeviceName != nil && !isExternalPlaybackActive && isPlaying {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("AirPlay Audio Only. For TV video on Samsung/LG/Roku, use Control Center → Screen Mirroring.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                }

                Spacer()

                // Subtitle display box
                if !activeSubtitleText.isEmpty {
                    HStack {
                        Spacer()
                        styledSubtitleView
                        Spacer()
                    }
                    .padding(.bottom, 12)
                    .padding(.horizontal, 16)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }

    // MARK: - Subtitle Render View

    @ViewBuilder
    private var styledSubtitleView: some View {
        let fontSize: CGFloat = {
            switch subtitleAppearance.size {
            case .small: return 14
            case .medium: return 16
            case .large: return 20
            }
        }()

        Text(activeSubtitleText)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Group {
                    if subtitleAppearance.background == .box {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.82))
                    } else if subtitleAppearance.background == .outline {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black, lineWidth: 2)
                    } else {
                        Color.clear
                    }
                }
            )
            .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
    }

    // MARK: - Controls HUD

    private var controlsHUD: some View {
        VStack(spacing: 12) {
            // Scrubber Timeline
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let effectiveDuration = duration > 0 ? duration : 180
                    let effectiveTime = isSeeking ? seekPreviewTime : currentTime
                    let progress = min(1.0, max(0.0, effectiveTime / effectiveDuration))

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 5)

                        Capsule()
                            .fill(cyanGradient)
                            .frame(width: max(6, geo.size.width * progress), height: 5)

                        Circle()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: Color(red: 0, green: 0.88, blue: 1).opacity(0.6), radius: 4)
                            .offset(x: max(0, min(geo.size.width - 14, (geo.size.width * progress) - 7)))
                    }
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                isSeeking = true
                                let ratio = min(1.0, max(0.0, val.location.x / geo.size.width))
                                seekPreviewTime = ratio * effectiveDuration
                            }
                            .onEnded { val in
                                let ratio = min(1.0, max(0.0, val.location.x / geo.size.width))
                                let target = ratio * effectiveDuration
                                seek(to: target)
                                isSeeking = false
                            }
                    )
                }
                .frame(height: 24)

                HStack {
                    Text(formatTime(isSeeking ? seekPreviewTime : currentTime))
                    Spacer()
                    Text("-" + formatTime(max(0, (duration > 0 ? duration : 180) - (isSeeking ? seekPreviewTime : currentTime))))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
            }

            // Transport Buttons
            HStack(spacing: 24) {
                // Skip backward 10s
                Button {
                    skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                // Previous
                Button {
                    playPrevious()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                // Primary Play / Pause
                Button {
                    togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(cyanGradient)
                            .frame(width: 52, height: 52)
                            .shadow(color: Color(red: 0, green: 0.88, blue: 1).opacity(0.4), radius: 8, y: 2)

                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: isPlaying ? 0 : 1.5)
                    }
                }

                // Next
                Button {
                    playNext()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                // Skip forward 10s
                Button {
                    skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.vertical, 2)

            // Speed & Volume Row
            HStack(spacing: 16) {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button("\(String(format: "%g×", rate))\(Float(rate) == playbackRate ? " ✓" : "")") {
                            playbackRate = Float(rate)
                            player.rate = playbackRate
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .font(.caption)
                        Text(String(format: "%g×", playbackRate))
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        isMuted.toggle()
                        player.isMuted = isMuted
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    Slider(value: $volume, in: 0...1) { _ in
                        player.volume = volume
                    }
                    .tint(Color(red: 0, green: 0.88, blue: 1))
                    .frame(width: 80)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .disabled(queue.isEmpty)
        .opacity(queue.isEmpty ? 0.6 : 1.0)
    }

    // MARK: - Playback Output Bento

    private var wirelessDestinationBento: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Playback Output", systemImage: "tv.and.mediabox")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showingCastSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add IP")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0, green: 0.88, blue: 1))
                }
            }

            VStack(spacing: 8) {
                // Local Display Option
                destinationCard(
                    title: "Local iPhone Display",
                    subtitle: "Zero-latency local fMP4 pipeline",
                    icon: "iphone.gen3",
                    badge: "DIRECT",
                    badgeColor: .blue,
                    isSelected: selectedReceiverName.contains("Local")
                ) {
                    selectedReceiverName = "Local iPhone Display"
                }

                // Connected AirPlay Receiver
                if let airplay = activeAirPlayDeviceName {
                    destinationCard(
                        title: airplay,
                        subtitle: isExternalPlaybackActive ? "AirPlay 2 Video Stream • TV Active" : "AirPlay Audio Connected • Use Screen Mirroring for Video",
                        icon: "tv",
                        badge: isExternalPlaybackActive ? "AIRPLAY VIDEO" : "AIRPLAY AUDIO",
                        badgeColor: isExternalPlaybackActive ? .cyan : .orange,
                        isSelected: selectedReceiverName == airplay
                    ) {
                        selectedReceiverName = airplay
                    }
                }

                // AirPlay Route Launcher
                HStack(spacing: 12) {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(red: 0, green: 0.88, blue: 1))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AirPlay Receivers")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        if isExternalPlaybackActive {
                            Text("Video streaming to \(activeAirPlayDeviceName ?? "AirPlay TV")")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                        } else if let name = activeAirPlayDeviceName {
                            Text("Audio connected to \(name) • For TV video, use Screen Mirroring")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        } else {
                            Text("Tap icon to route to Apple TV or AirPlay TV")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Spacer()
                    IOSAirPlayRoutePicker()
                        .frame(width: 32, height: 32)
                }
                .padding(10)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if castDevices.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.white.opacity(0.4))
                            .font(.system(size: 13))
                        Text("No network receivers added. Tap 'Add IP' to connect.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                } else {
                    // Chromecast Card
                    ForEach(castDevices.filter { $0.kind == .chromecast }) { dev in
                        destinationCard(
                            title: dev.name,
                            subtitle: "CastV2 TLS :\(dev.port) • Ultra 4K",
                            icon: "tv",
                            badge: "CHROMECAST",
                            badgeColor: .orange,
                            isSelected: selectedReceiverName == dev.name
                        ) {
                            selectedReceiverName = dev.name
                        }
                    }

                    // DLNA / Miracast Card
                    ForEach(castDevices.filter { $0.kind == .miracastDLNA }) { dev in
                        destinationCard(
                            title: dev.name,
                            subtitle: "\(dev.model) • UPnP AVTransport",
                            icon: "display",
                            badge: "DLNA",
                            badgeColor: .purple,
                            isSelected: selectedReceiverName == dev.name
                        ) {
                            selectedReceiverName = dev.name
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func destinationCard(
        title: String,
        subtitle: String,
        icon: String,
        badge: String,
        badgeColor: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? cyanGradient : LinearGradient(colors: [Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.85))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(badgeColor.opacity(0.22))
                            .foregroundStyle(badgeColor)
                            .clipShape(Capsule())
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0, green: 0.88, blue: 1))
                        .font(.system(size: 18))
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color(red: 0, green: 0.88, blue: 1).opacity(0.12) : Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isSelected ? Color(red: 0, green: 0.88, blue: 1).opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Up Next Queue Bento

    private var queueSectionBento: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Label("Up Next Queue", systemImage: "list.and.film")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(queue.count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.15))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }

                Spacer()

                Button {
                    isImportingFiles = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0, green: 0.88, blue: 1))
                }

                if !queue.isEmpty {
                    Button("Clear") {
                        queue.removeAll()
                        player.replaceCurrentItem(with: nil)
                        isPlaying = false
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                }
            }

            VStack(spacing: 6) {
                if queue.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Queue is empty")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                        Button {
                            isImportingFiles = true
                        } label: {
                            Text("Add Media Files")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0, green: 0.88, blue: 1))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ForEach(Array(queue.enumerated()), id: \.offset) { idx, url in
                        let isCurrent = (idx == queueIndex)
                        Button {
                            queueIndex = idx
                            loadCurrentItem()
                        } label: {
                            queueRow(
                                title: url.deletingPathExtension().lastPathComponent,
                                subtitle: url.pathExtension.uppercased(),
                                isPlaying: isCurrent,
                                indexText: "\(idx + 1)"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func queueRow(title: String, subtitle: String, isPlaying: Bool, indexText: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isPlaying ? cyanGradient : LinearGradient(colors: [Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 26, height: 26)

                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text(indexText)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: isPlaying ? .bold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            if isPlaying {
                Text("PLAYING")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(red: 0, green: 0.88, blue: 1))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0, green: 0.88, blue: 1).opacity(0.18))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isPlaying ? Color(red: 0, green: 0.88, blue: 1).opacity(0.12) : Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isPlaying ? Color(red: 0, green: 0.88, blue: 1).opacity(0.35) : Color.clear, lineWidth: 1)
                )
        )
    }

    // MARK: - Dual Screen Deck Container

    private func deckContent(posture: DualScreenPosture) -> some View {
        VStack(spacing: 14) {
            HStack {
                Label(posture.rawValue, systemImage: "rectangle.split.2x1.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0, green: 0.88, blue: 1))
                Spacer()
                Button("-0.25s") { subtitleOffset -= 0.25 }
                    .font(.caption2.weight(.bold))
                    .buttonStyle(.bordered)
                Text(String(format: "%+.2fs", subtitleOffset))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                Button("+0.25s") { subtitleOffset += 0.25 }
                    .font(.caption2.weight(.bold))
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 4)

            if posture == .tabletopHorizontalHinge {
                controlsHUD
            }

            wirelessDestinationBento
            queueSectionBento
        }
        .padding(14)
    }

    // MARK: - Helpers & Playback Control

    private var currentTitle: String {
        if queue.indices.contains(queueIndex) {
            return queue[queueIndex].deletingPathExtension().lastPathComponent
        }
        return "No Media Loaded"
    }

    private var currentFormatBadge: String {
        guard !queue.isEmpty else { return "READY" }
        let title = currentTitle.lowercased()
        if title.contains("hevc") || title.contains("265") {
            return "4K HEVC"
        } else if title.contains("av1") {
            return "1080p AV1"
        } else if title.contains("hdr") {
            return "HDR10"
        } else if title.contains("atmos") {
            return "Dolby Atmos"
        }
        return queue[queueIndex].pathExtension.uppercased()
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            guard !isSeeking else { return }
            currentTime = time.seconds
            if let cur = player.currentItem, cur.duration.isNumeric {
                duration = cur.duration.seconds
            }
            isPlaying = (player.timeControlStatus == .playing)
            if let err = player.currentItem?.error {
                handlePlaybackFailure(err)
            }
        }
    }

    private func togglePlayPause() {
        guard !queue.isEmpty else { return }
        if player.currentItem?.status == .failed, let err = player.currentItem?.error {
            handlePlaybackFailure(err)
            return
        }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            player.play()
            isPlaying = true
            UIApplication.shared.isIdleTimerDisabled = preventSleep
        }
    }

    private func seek(to seconds: Double) {
        guard !queue.isEmpty else { return }
        currentTime = seconds
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func skip(by seconds: Double) {
        guard !queue.isEmpty else { return }
        let newTime = max(0, min(duration > 0 ? duration : 180, currentTime + seconds))
        seek(to: newTime)
    }

    private func playPrevious() {
        guard !queue.isEmpty, queueIndex > 0 else { return }
        queueIndex -= 1
        loadCurrentItem()
    }

    private func playNext() {
        guard !queue.isEmpty, queueIndex + 1 < queue.count else { return }
        queueIndex += 1
        loadCurrentItem()
    }

    private func updateConnectedRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if let airplay = outputs.first(where: { $0.portType == .airPlay || $0.portType.rawValue.localizedCaseInsensitiveContains("hdmi") }) {
            let name = airplay.portName.isEmpty ? "AirPlay TV" : airplay.portName
            activeAirPlayDeviceName = name
            selectedReceiverName = name
            player.allowsExternalPlayback = true
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
            if !queue.isEmpty && !isPlaying {
                player.play()
                isPlaying = true
                UIApplication.shared.isIdleTimerDisabled = preventSleep
            }
        } else {
            activeAirPlayDeviceName = nil
            if !castDevices.contains(where: { $0.name == selectedReceiverName }) {
                selectedReceiverName = "Local iPhone Display"
            }
        }
    }

    private func handlePlaybackFailure(_ error: Error) {
        let nsError = error as NSError
        // Always preserve external video playback capabilities
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        withAnimation {
            if nsError.domain == AVFoundationErrorDomain && nsError.code == AVError.externalPlaybackNotSupportedForAsset.rawValue {
                errorMessage = "This TV cannot stream this video format directly via AirPlay. Swipe down for iOS Control Center and tap Screen Mirroring to mirror video."
            } else {
                errorMessage = PlaybackDiagnostics.guidance(error, external: isExternalPlaybackActive || activeAirPlayDeviceName != nil)
            }
        }
    }

    private func setupAudioSessionAndAirPlay() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            try session.setActive(true)
        } catch {
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                print("Audio session error: \(error)")
            }
        }
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.preventsDisplaySleepDuringVideoPlayback = true
    }

    private func stageURLs(_ urls: [URL]) -> [URL] {
        var stagedURLs: [URL] = []
        for url in urls {
            switch IOSMediaStager.stage(url: url) {
            case let .ready(stagedURL):
                stagedURLs.append(stagedURL)
            case let .unsupported(message):
                withAnimation { errorMessage = message }
            case let .failed(message):
                withAnimation { errorMessage = message }
            }
        }
        return stagedURLs
    }

    private func openQueue(_ urls: [URL]) {
        let staged = stageURLs(urls)
        guard !staged.isEmpty else { return }
        queue = staged
        queueIndex = 0
        loadCurrentItem(autoPlay: false)
    }

    private func loadCurrentItem(autoPlay: Bool = false) {
        guard queue.indices.contains(queueIndex) else { return }
        withAnimation { errorMessage = nil }
        let url = queue[queueIndex]
        _ = url.startAccessingSecurityScopedResource()
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        currentTime = 0

        activeFileServer?.stop()
        let fileServer = StreamFileServer(fileURL: url)
        activeFileServer = fileServer

        Task {
            let playbackURL: URL
            do {
                playbackURL = try await fileServer.start()
            } catch {
                playbackURL = url
            }
            await MainActor.run {
                let item = AVPlayerItem(url: playbackURL)
                player.replaceCurrentItem(with: item)

                let isExternal = isExternalPlaybackActive || activeAirPlayDeviceName != nil || selectedReceiverName != "Local iPhone Display"
                if autoPlay || isExternal {
                    player.play()
                    isPlaying = true
                    UIApplication.shared.isIdleTimerDisabled = preventSleep
                } else {
                    player.pause()
                    isPlaying = false
                    UIApplication.shared.isIdleTimerDisabled = false
                }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                    MPMediaItemPropertyTitle: currentTitle,
                    MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
                ]
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "00:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Subtitle Appearance & Sync Sheet

struct IOSSubtitleSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var appearance: SubtitleAppearance
    @Binding var offset: Double
    let previewText: String

    var body: some View {
        NavigationStack {
            Form {
                Section("Live Preview") {
                    VStack(spacing: 8) {
                        ZStack {
                            Color(red: 0.08, green: 0.09, blue: 0.13)
                                .frame(height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                            Text(previewText)
                                .font(.system(size: appearance.size == .small ? 13 : (appearance.size == .medium ? 16 : 19), weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(
                                    Group {
                                        if appearance.background == .box {
                                            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.8))
                                        } else if appearance.background == .outline {
                                            RoundedRectangle(cornerRadius: 6).stroke(Color.black, lineWidth: 2)
                                        }
                                    }
                                )
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Timing Synchronization") {
                    HStack {
                        Text("Current Offset")
                        Spacer()
                        Text(String(format: "%+.2fs", offset))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("-0.25s Earlier") { offset -= 0.25 }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Reset") { offset = 0.0 }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("+0.25s Later") { offset += 0.25 }
                            .buttonStyle(.bordered)
                    }
                }

                Section("Typography & Styling") {
                    Picker("Font Size", selection: $appearance.size) {
                        ForEach(SubtitleAppearance.Size.allCases, id: \.self) { size in
                            Text(size.rawValue.capitalized).tag(size)
                        }
                    }

                    Picker("Background Box", selection: $appearance.background) {
                        ForEach(SubtitleAppearance.Background.allCases, id: \.self) { bg in
                            Text(bg.rawValue.capitalized).tag(bg)
                        }
                    }

                    Picker("Vertical Position", selection: $appearance.position) {
                        ForEach(SubtitleAppearance.Position.allCases, id: \.self) { pos in
                            Text(pos.rawValue.capitalized).tag(pos)
                        }
                    }
                }
            }
            .navigationTitle("Subtitle Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        appearance.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Manual Cast / DLNA IP Connect Sheet

struct IOSCastConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var devices: [CastReceiverDevice]
    @Binding var selectedDevice: String
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "8009"
    @State private var kind: CastReceiverKind = .chromecast

    var body: some View {
        NavigationStack {
            Form {
                Section("Receiver Type") {
                    Picker("Protocol", selection: $kind) {
                        Text("Chromecast (TLS :8009)").tag(CastReceiverKind.chromecast)
                        Text("Miracast / DLNA (UPnP)").tag(CastReceiverKind.miracastDLNA)
                    }
                    .onChange(of: kind) { _, newKind in
                        if newKind == .chromecast && port == "1400" { port = "8009" }
                        if newKind == .miracastDLNA && port == "8009" { port = "1400" }
                    }
                }

                Section("Connection Details") {
                    TextField("Friendly Name (e.g. Den OLED TV)", text: $name)
                    TextField("IP Address (e.g. 192.168.1.50)", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }

                Section {
                    Button("Connect to Receiver") {
                        let p = UInt16(port) ?? (kind == .chromecast ? 8009 : 1400)
                        let newDev = CastReceiverDevice(
                            id: UUID().uuidString,
                            name: name.isEmpty ? (kind == .chromecast ? "Chromecast \(host)" : "DLNA TV \(host)") : name,
                            model: kind == .chromecast ? "CastV2 TLS :\(p)" : "UPnP AVTransport",
                            kind: kind,
                            endpoint: nil,
                            host: host,
                            port: p,
                            controlURL: kind == .miracastDLNA ? URL(string: "http://\(host):\(p)/MediaRenderer/AVTransport/Control") : nil
                        )
                        devices.append(newDev)
                        selectedDevice = newDev.name
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Add Network Receiver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Native iOS Video Canvas Bridge

struct IOSVideoCanvas: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

// MARK: - Native AirPlay Route Picker Bridge

struct IOSAirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = UIColor(red: 0, green: 0.88, blue: 1, alpha: 1)
        picker.activeTintColor = UIColor(red: 0.15, green: 0.45, blue: 1, alpha: 1)
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

#if !AIRPLAYR_IOS_TEST_RUNNER
@main
struct AirPlayrIOSMainApp: App {
    var body: some Scene {
        WindowGroup {
            AirPlayrIOSView()
                .preferredColorScheme(.dark)
        }
    }
}
#endif
#endif
