#if os(iOS)
import SwiftUI
import AVKit
import MediaPlayer
import UniformTypeIdentifiers

// MARK: - Dual Screen Postures

/// Posture states for iPhone Fold / Duo, iPad Split View, and Dual-Screen hardware.
enum DualScreenPosture: String, CaseIterable, Equatable, Sendable {
    case singleScreen = "Single Screen"
    case tabletopHorizontalHinge = "Tabletop (Top Video / Bottom Deck)"
    case bookVerticalHinge = "Book / Dual-Screen (Left Video / Right Deck)"
    case externalDisplayExtended = "External Display Extended"

    /// Resolves the optimal dual-screen/foldable layout posture from viewport geometry, hinge rect, and external screen state.
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
        // Unfolded square-ish inner foldable displays (e.g., iPhone Fold / Duo book posture ~ 0.85..1.25 at >=600pt width)
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
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color(red: 0, green: 0.88, blue: 1).opacity(0.35), radius: 6, y: 1)
                .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: -0.5) {
                Text("airplay")
                    .foregroundStyle(.white)
                    .tracking(-0.6)
                Text("r")
                    .bold()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0, green: 0.88, blue: 1), Color(red: 0.15, green: 0.45, blue: 1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .font(.system(size: 22, weight: .bold))

            Text("iOS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 0, green: 0.88, blue: 1))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(red: 0, green: 0.88, blue: 1).opacity(0.16))
                .clipShape(Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AirPlayr for iOS")
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
    @State private var activeSubtitleText: String = "♪ Zero-Re-Encode 4K fMP4 HLS Ready ♪"
    @State private var showingSubtitleSheet = false
    @State private var showingCastSheet = false
    @State private var preventSleep: Bool = true
    @State private var playbackRate: Float = 1.0
    @State private var isMuted: Bool = false
    @State private var volume: Float = 1.0

    @State private var castDevices: [CastReceiverDevice] = [
        CastReceiverDevice(id: "cc-1", name: "Living Room Chromecast 4K", model: "CastV2 TLS :8009", kind: .chromecast, endpoint: nil, host: "192.168.1.40", port: 8009, controlURL: nil),
        CastReceiverDevice(id: "dlna-1", name: "Living Room Smart TV (DLNA)", model: "UPnP AVTransport:1", kind: .miracastDLNA, endpoint: nil, host: "192.168.1.55", port: 1400, controlURL: URL(string: "http://192.168.1.55:1400/MediaRenderer/AVTransport/Control"))
    ]
    @State private var selectedReceiverName: String = "Local iPhone Display"
    @State private var simulatedHingeGutter: CGFloat = 12

    @State private var demoTracks: [String] = [
        "Big_Buck_Bunny_4K_HEVC.mkv",
        "Tears_of_Steel_1080p_AV1.mkv",
        "Sintel_Open_Movie_HDR.mp4",
        "Cosmos_Laundromat_Atmos.mov"
    ]
    @State private var demoTrackIndex: Int = 0

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
                ZStack {
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
                    allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .audio],
                    allowsMultipleSelection: true
                ) { result in
                    if case let .success(urls) = result, !urls.isEmpty {
                        openQueue(urls)
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
                }
            }
        }
    }

    // MARK: - Video Canvas Stage

    private var videoStage: some View {
        ZStack(alignment: .bottom) {
            Color.black

            VideoPlayer(player: player)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

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
                        .fill(selectedReceiverName.contains("Local") ? Color.blue : Color.green)
                        .frame(width: 8, height: 8)
                        .shadow(color: (selectedReceiverName.contains("Local") ? Color.blue : Color.green).opacity(0.8), radius: 4)
                }
                .padding(12)
                .background(.ultraThinMaterial.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.top, 10)

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
    }

    // MARK: - Wireless Destinations Bento

    private var wirelessDestinationBento: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Wireless Destinations", systemImage: "antenna.radiowaves.left.and.right")
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
                    title: "Local iPhone / Fold Display",
                    subtitle: "Zero-latency local fMP4 pipeline",
                    icon: "iphone.gen3",
                    badge: "DIRECT",
                    badgeColor: .blue,
                    isSelected: selectedReceiverName.contains("Local")
                ) {
                    selectedReceiverName = "Local iPhone Display"
                }

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
                    Text("\(queue.isEmpty ? demoTracks.count : queue.count)")
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
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                }
            }

            VStack(spacing: 6) {
                if queue.isEmpty {
                    ForEach(Array(demoTracks.enumerated()), id: \.offset) { idx, title in
                        let isCurrent = (idx == demoTrackIndex)
                        Button {
                            demoTrackIndex = idx
                        } label: {
                            queueRow(
                                title: title,
                                subtitle: "Zero-Re-Encode HLS Demo",
                                isPlaying: isCurrent,
                                indexText: "\(idx + 1)"
                            )
                        }
                        .buttonStyle(.plain)
                    }
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
        return demoTracks[demoTrackIndex]
    }

    private var currentFormatBadge: String {
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
        return "fMP4 HLS"
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
        }
    }

    private func togglePlayPause() {
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
        currentTime = seconds
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func skip(by seconds: Double) {
        let newTime = max(0, min(duration > 0 ? duration : 180, currentTime + seconds))
        seek(to: newTime)
    }

    private func playPrevious() {
        if !queue.isEmpty {
            guard queueIndex > 0 else { return }
            queueIndex -= 1
            loadCurrentItem()
        } else if demoTrackIndex > 0 {
            demoTrackIndex -= 1
        }
    }

    private func playNext() {
        if !queue.isEmpty {
            guard queueIndex + 1 < queue.count else { return }
            queueIndex += 1
            loadCurrentItem()
        } else if demoTrackIndex + 1 < demoTracks.count {
            demoTrackIndex += 1
        }
    }

    private func openQueue(_ urls: [URL]) {
        queue = urls
        queueIndex = 0
        loadCurrentItem()
    }

    private func loadCurrentItem() {
        guard queue.indices.contains(queueIndex) else { return }
        let url = queue[queueIndex]
        _ = url.startAccessingSecurityScopedResource()
        let item = AVPlayerItem(url: url)
        player.allowsExternalPlayback = true
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        UIApplication.shared.isIdleTimerDisabled = preventSleep
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
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
