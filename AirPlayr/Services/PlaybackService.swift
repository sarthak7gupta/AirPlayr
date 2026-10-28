import AVFoundation
import AppKit
import IOKit.pwr_mgt
import MediaPlayer
import Observation
import OSLog

/// Owns the app's single `AVPlayer`, security-scoped file access, and playback UI state.
///
/// Direct playback uses AVFoundation when the source is playable. When AirPlay rejects the asset,
/// external SRT is loaded while routed externally, or MKV/H.264/HEVC preparation is required,
/// `prepareTV` switches to an on-demand HLS compatibility stream (`AutomaticStreamSession`) while
/// preserving the full-movie timeline for seeking.
@MainActor @Observable final class PlaybackService {
    let player = AVPlayer()
    let cast = CastService()
    private(set) var preventSleepWhilePlaying: Bool = (UserDefaults.standard.object(forKey: "preventSleepWhilePlaying") as? Bool) ?? true
    private(set) var isPreventingSleep = false
    @ObservationIgnored private var sleepAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private(set) var isPreparingForTV = false { didSet { updateSleepAssertion() } }
    private(set) var isCompatibilityStreaming = false
    @ObservationIgnored private var stream: AutomaticStreamSession?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamStart: Double?
    @ObservationIgnored private var wantsPlayback = false { didSet { updateSleepAssertion() } }
    static let minimumPlaybackRate: Float = 0.5
    static let maximumPlaybackRate: Float = 4
    static let playbackRates: [Float] = (2...16).map { Float($0) / 4 }
    private(set) var playbackRate: Float = 1
    private(set) var actualPlaybackRate: Float = 0
    @ObservationIgnored private var subtitleFolderAccess: FileAccess?
    private(set) var subtitleAppearance = SubtitleAppearance.load()
    private(set) var burnSubtitlesForTV = false
    private(set) var subtitleOffsetSeconds: Double = 0.0
    var preferredAudioLanguage: String = UserDefaults.standard.string(forKey: "preferredAudioLanguage") ?? "" {
        didSet { UserDefaults.standard.set(preferredAudioLanguage, forKey: "preferredAudioLanguage") }
    }
    var preferredSubtitleLanguage: String = UserDefaults.standard.string(forKey: "preferredSubtitleLanguage") ?? "" {
        didSet { UserDefaults.standard.set(preferredSubtitleLanguage, forKey: "preferredSubtitleLanguage") }
    }
    private(set) var queue: [URL] = []
    private(set) var queueIndex: Int = 0
    var autoPlayNext: Bool = (UserDefaults.standard.object(forKey: "autoPlayNext") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoPlayNext, forKey: "autoPlayNext") }
    }
    var resumePlaybackEnabled: Bool = (UserDefaults.standard.object(forKey: "resumePlaybackEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(resumePlaybackEnabled, forKey: "resumePlaybackEnabled") }
    }
    var zeroReencodePassthroughEnabled: Bool = (UserDefaults.standard.object(forKey: "zeroReencodePassthroughEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(zeroReencodePassthroughEnabled, forKey: "zeroReencodePassthroughEnabled") }
    }
    var ssdpDiscoveryEnabled: Bool = (UserDefaults.standard.object(forKey: "ssdpDiscoveryEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(ssdpDiscoveryEnabled, forKey: "ssdpDiscoveryEnabled")
            if ssdpDiscoveryEnabled { cast.startDiscovery() }
        }
    }
    var canPlayPrevious: Bool { queueIndex > 0 && queueIndex < queue.count }
    var canPlayNext: Bool { queueIndex + 1 < queue.count }
    static let supportedMediaExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv"]
    var sourceURL: URL? { scope?.url }
    private(set) var phase: PlaybackPhase = .empty { didSet { updateSleepAssertion(); updateNowPlayingInfo() } }
    private(set) var position = 0.0
    private(set) var duration: Double?
    private(set) var externalPlayback = false { didSet { updateSleepAssertion() } }
    private(set) var routeMessage: String?
    private(set) var title = "AirPlayr"
    private(set) var dimensions: String?
    private(set) var artwork: NSImage?
    private(set) var subtitleGroup: AVMediaSelectionGroup?
    private(set) var audioGroup: AVMediaSelectionGroup?
    private(set) var subtitleSelection: AVMediaSelectionOption?
    private(set) var audioSelection: AVMediaSelectionOption?
    private(set) var externalSubtitles: SubtitleDocument?
    private(set) var externalSubtitleName: String?
    private(set) var subtitleText = ""
    var issue: String?
    private(set) var diagnosticCode: String?
    @ObservationIgnored private let logger = Logger(subsystem: "com.airplayr.app", category: "Playback")
    private(set) var isMuted = false
    var volume: Float = 1 { didSet { player.volume = volume } }
    @ObservationIgnored private var scope: FileAccess?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var periodic: Any?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var seekGeneration = UUID()
    @ObservationIgnored private var entryID: UUID?
    @ObservationIgnored private var lastSavedPosition = 0.0
    @ObservationIgnored private let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = false
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshPhase() }
        })
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleExternalPlaybackChange(active)
            }
        })
        observations.append(player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let rate = player.rate
            Task { @MainActor [weak self] in self?.actualPlaybackRate = rate }
        })
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isPreparingForTV, self.phase != .seeking, time.seconds.isFinite else { return }
                self.position = max(0, time.seconds)
                self.subtitleText = self.activeSubtitleText(at: self.position)
                if abs(self.position - self.lastSavedPosition) >= 5 { self.checkpoint(); self.updateNowPlayingInfo() }
            }
        }
        setupRemoteCommands()
    }

    private func activeSubtitleText(at seconds: Double) -> String {
        externalSubtitles?.text(at: seconds - subtitleOffsetSeconds) ?? ""
    }

    static func expandMediaURLs(_ urls: [URL]) -> [URL] {
        var expanded: [URL] = []
        var seen: Set<URL> = []
        for url in urls {
            let scope = FileAccess(url)
            defer { withExtendedLifetime(scope) {} }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    let sorted = children.filter { supportedMediaExtensions.contains($0.pathExtension.lowercased()) }
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    for child in sorted where seen.insert(child.standardizedFileURL).inserted {
                        expanded.append(child)
                    }
                }
            } else if supportedMediaExtensions.contains(url.pathExtension.lowercased()),
                      seen.insert(url.standardizedFileURL).inserted {
                expanded.append(url)
            }
        }
        return expanded
    }

    func openFiles(_ urls: [URL]) {
        let expanded = Self.expandMediaURLs(urls)
        guard let first = expanded.first else {
            if let raw = urls.first { open(raw) }
            return
        }
        queue = expanded
        queueIndex = 0
        open(first, updatingQueue: false)
    }

    func enqueue(_ urls: [URL]) {
        let expanded = Self.expandMediaURLs(urls)
        guard !expanded.isEmpty else { return }
        if queue.isEmpty || sourceURL == nil {
            openFiles(expanded)
            return
        }
        let existing = Set(queue.map(\.standardizedFileURL))
        for item in expanded where !existing.contains(item.standardizedFileURL) {
            queue.append(item)
        }
        updateNowPlayingInfo()
    }

    func playNext() {
        guard canPlayNext else { return }
        queueIndex += 1
        wantsPlayback = true
        open(queue[queueIndex], updatingQueue: false)
    }

    func playPrevious() {
        guard canPlayPrevious else { return }
        queueIndex -= 1
        wantsPlayback = true
        open(queue[queueIndex], updatingQueue: false)
    }

    func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queueIndex = index
        wantsPlayback = true
        open(queue[index], updatingQueue: false)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let removingCurrent = (index == queueIndex)
        queue.remove(at: index)
        if queue.isEmpty {
            queueIndex = 0
            if removingCurrent { stop() }
        } else if removingCurrent {
            queueIndex = min(index, queue.count - 1)
            open(queue[queueIndex], updatingQueue: false)
        } else if index < queueIndex {
            queueIndex -= 1
        }
        updateNowPlayingInfo()
    }

    func clearQueue() {
        if let current = sourceURL {
            queue = [current]
            queueIndex = 0
        } else {
            queue.removeAll()
            queueIndex = 0
        }
        updateNowPlayingInfo()
    }

    func open(_ url: URL, resume: Double = 0, updatingQueue: Bool = true) {
        if updatingQueue {
            if let existing = queue.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                queueIndex = existing
            } else {
                queue = [url]
                queueIndex = 0
            }
        }
        checkpoint()
        loadTask?.cancel(); subtitleTask?.cancel()
        generation = UUID()
        let token = generation
        clearItem()
        subtitleOffsetSeconds = 0
        issue = nil; diagnosticCode = nil; routeMessage = nil; phase = .loading
        let access = FileAccess(url)
        scope = access
        subtitleFolderAccess = SubtitleFolderStore.access(for: url)
        title = url.deletingPathExtension().lastPathComponent
        updateNowPlayingInfo()
        loadTask = Task { [weak self, access] in
            defer { withExtendedLifetime(access) {} }
            guard let self else { return }
            do {
                try MediaPolicy.validate(url)
                let entry = try library.remember(url)
                entryID = entry.id
                let asset = AVURLAsset(url: url)
                if await MKVBridge.needsPreparation(url, asset: asset) {
                    let metadata = try await MKVBridge.inspect(url)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    duration = metadata.duration
                    if let video = metadata.video, let width = video.width, let height = video.height { dimensions = "\(width) × \(height)" }
                    let companion = SubtitleDocument.companionURL(for: url)
                    let companionDoc = try? await Task.detached(priority: .userInitiated, operation: { try SubtitleDocument.read(companion) }).value
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    if let doc = companionDoc { externalSubtitles = doc; externalSubtitleName = companion.lastPathComponent }
                    let saved = resume > 0 ? resume : entry.position
                    prepareTV(at: saved < (duration ?? 0) - 2 ? saved : 0, play: wantsPlayback)
                    return
                }
                let playable = try await asset.load(.isPlayable)
                guard playable else { throw MediaIssue.unsupported }
                let length = try await asset.load(.duration).seconds
                let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
                let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                var sizeText: String?
                if let video = tracks.first {
                    let size = try await video.load(.naturalSize)
                    sizeText = "\(Int(abs(size.width))) × \(Int(abs(size.height)))"
                }
                let metadata = (try? await asset.load(.commonMetadata)) ?? []
                var image: NSImage?
                if let item = metadata.first(where: { $0.commonKey == .commonKeyArtwork }), let data = try? await item.load(.dataValue) { image = NSImage(data: data) }
                try Task.checkCancellation()
                guard generation == token else { return }
                duration = length.isFinite && length > 0 ? length : nil
                dimensions = sizeText; artwork = image
                subtitleGroup = subtitles; audioGroup = audio
                let item = AVPlayerItem(asset: asset)
                player.replaceCurrentItem(with: item)
                if let subtitles {
                    let preferredSub = Self.matchingOption(in: subtitles, preferredLanguage: preferredSubtitleLanguage)
                    item.select(preferredSub, in: subtitles)
                    subtitleSelection = preferredSub
                }
                if let audio {
                    if let preferredAud = Self.matchingOption(in: audio, preferredLanguage: preferredAudioLanguage) {
                        item.select(preferredAud, in: audio)
                        audioSelection = preferredAud
                    } else {
                        audioSelection = item.currentMediaSelection.selectedMediaOption(in: audio)
                    }
                }
                installItemObservers(item, generation: token)
                phase = .ready
                updateNowPlayingInfo()
                let saved = resume > 0 ? resume : entry.position
                if let duration, saved > 0, saved < duration - 2 { seek(to: saved) }
                loadSubtitles(SubtitleDocument.companionURL(for: url), automatic: true)
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                phase = .failed
                recordError(error)
                issue = (error as? MediaIssue)?.localizedDescription ?? (error as? StreamFailure)?.message ?? "This media could not be loaded. Reopen the file or try a compatible MP4."
                scope = nil
            }
        }
    }
    /// Called by the real AVPlayer external-playback observation, not route-picker clicks.
    func handleExternalPlaybackChange(_ active: Bool) {
        let newlyConnected = active && !externalPlayback
        if externalPlayback != active {
            routeMessage = active ? "External video playback is active." : "External video playback ended. Check the output in the AirPlay menu."
        }
        externalPlayback = active
        if newlyConnected, player.currentItem != nil, phase != .failed {
            wantsPlayback = true
            if !isPreparingForTV, player.currentItem?.status == .readyToPlay { player.playImmediately(atRate: playbackRate) }
        }
        if active, externalSubtitles != nil, !isCompatibilityStreaming, !isPreparingForTV {
            prepareTV(at: position, play: wantsPlayback)
        }
    }
    private func installItemObservers(_ item: AVPlayerItem, generation token: UUID) {
        // Player observations are retained at indices 0 through 2; item observers are replaced on every open.
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if item.status == .failed { self.failPlayback(item.error) }
                else {
                    if item.status == .readyToPlay, self.isCompatibilityStreaming, let start = self.streamStart {
                        self.streamStart = nil
                        if start > 0 { self.seek(to: start) }
                        if self.wantsPlayback { self.player.playImmediately(atRate: self.playbackRate) }
                    }
                    if item.status == .readyToPlay, !self.isCompatibilityStreaming, self.wantsPlayback {
                        self.player.playImmediately(atRate: self.playbackRate)
                    }
                    self.refreshPhase()
                }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if let group = self.subtitleGroup { self.subtitleSelection = item.currentMediaSelection.selectedMediaOption(in: group) }
                if let group = self.audioGroup { self.audioSelection = item.currentMediaSelection.selectedMediaOption(in: group) }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.phase = .ended; self.checkpoint()
                if self.autoPlayNext, self.canPlayNext {
                    self.playNext()
                }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.failPlayback(error ?? item.error)
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.phase = .waiting
            }
        })
    }
    private func recordError(_ error: Error?) {
        diagnosticCode = PlaybackDiagnostics.code(error)
        logger.error("Playback failure: \(PlaybackDiagnostics.code(error), privacy: .public); external=\(self.player.isExternalPlaybackActive)")
    }
    private func failPlayback(_ error: Error?) {
        if !isCompatibilityStreaming, !isPreparingForTV, dimensions != nil,
           (error as NSError?)?.domain == AVFoundationErrorDomain,
           (error as NSError?)?.code == AVError.externalPlaybackNotSupportedForAsset.rawValue {
            prepareTV(at: position, play: wantsPlayback)
            return
        }
        seekGeneration = UUID()
        phase = .failed
        player.pause(); stream?.stop()
        recordError(error ?? player.error)
        issue = PlaybackDiagnostics.guidance(error ?? player.error, external: player.isExternalPlaybackActive)
        checkpoint()
    }
    func retry() {
        guard let scope else { return }
        open(scope.url, resume: position)
    }
    private func refreshPhase() {
        guard !isPreparingForTV, let item = player.currentItem, phase != .seeking, phase != .ended, phase != .failed else { return }
        if item.status == .failed { failPlayback(item.error); return }
        if item.status == .unknown { phase = .loading; return }
        switch player.timeControlStatus {
        case .playing: phase = .playing
        case .waitingToPlayAtSpecifiedRate: phase = .waiting
        case .paused: if phase != .ready { phase = .paused }
        @unknown default: phase = .waiting
        }
    }
    func togglePlayback() {
        if isPreparingForTV { wantsPlayback.toggle(); return }
        guard player.currentItem != nil, phase != .failed else { return }
        if player.timeControlStatus == .paused {
            if phase == .ended { seek(to: 0) }
            wantsPlayback = true
            if isCompatibilityStreaming { player.playImmediately(atRate: playbackRate) } else { player.rate = playbackRate }
            cast.sendPlaybackState(playing: true)
        } else {
            wantsPlayback = false; player.pause(); checkpoint()
            cast.sendPlaybackState(playing: false)
        }
    }
    func seek(to seconds: Double) {
        guard phase != .failed, let duration, let target = MediaPolicy.seekTarget(seconds, duration: duration), player.currentItem != nil || isPreparingForTV else { return }
        streamStart = nil
        cast.sendSeek(to: target)
        if isPreparingForTV {
            prepareTV(at: min(target, max(0, duration - 0.1)), play: wantsPlayback)
            return
        }
        let itemToken = generation
        seekGeneration = UUID()
        let seekToken = seekGeneration
        phase = .seeking; position = target
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == itemToken, self.seekGeneration == seekToken else { return }
                self.position = max(0, self.player.currentTime().seconds.isFinite ? self.player.currentTime().seconds : 0)
                self.subtitleText = self.activeSubtitleText(at: self.position)
                self.phase = .paused
                if finished, self.wantsPlayback, self.player.rate == 0, self.player.currentItem?.status == .readyToPlay {
                    if self.isCompatibilityStreaming { self.player.playImmediately(atRate: self.playbackRate) }
                    else { self.player.rate = self.playbackRate }
                }
                self.refreshPhase()
                if !finished { self.issue = "Seeking was interrupted. Try the timeline again." }
                self.checkpoint()
                self.updateNowPlayingInfo()
            }
        }
    }
    func setPlaybackRate(_ rate: Float) {
        guard Self.playbackRates.contains(rate) else { return }
        playbackRate = rate
        if wantsPlayback, !isPreparingForTV, player.currentItem?.status == .readyToPlay { player.playImmediately(atRate: rate) }
    }
    func stepPlaybackRate(increase: Bool) {
        setPlaybackRate(min(Self.maximumPlaybackRate, max(Self.minimumPlaybackRate, playbackRate + (increase ? 0.25 : -0.25))))
    }
    func allowSubtitleFolder(_ folder: URL) {
        guard let sourceURL, folder.standardizedFileURL == sourceURL.deletingLastPathComponent().standardizedFileURL else {
            issue = "Choose the folder containing the current movie."; return
        }
        do {
            try SubtitleFolderStore.remember(folder)
            subtitleFolderAccess = SubtitleFolderStore.access(for: sourceURL)
            loadSubtitles(SubtitleDocument.companionURL(for: sourceURL), automatic: true)
        } catch { issue = "Folder access could not be saved. You can still load the SRT directly." }
    }
    func adjustVolume(_ delta: Float) { volume = min(1, max(0, volume + delta)); isMuted = false; player.isMuted = false }
    func toggleMute() { isMuted.toggle(); player.isMuted = isMuted }
    func skip(_ seconds: Double) { seek(to: position + seconds) }
    func selectSubtitle(_ option: AVMediaSelectionOption?) {
        subtitleTask?.cancel()
        if isCompatibilityStreaming, !burnSubtitlesForTV {
            if let subtitleGroup { player.currentItem?.select(option, in: subtitleGroup) }
            subtitleSelection = option
            return
        }
        externalSubtitles = nil; externalSubtitleName = nil; subtitleText = ""
        if let subtitleGroup { player.currentItem?.select(option, in: subtitleGroup) }
        subtitleSelection = option
        if isCompatibilityStreaming { prepareTV(at: position, play: wantsPlayback) }
    }
    func selectAudio(_ option: AVMediaSelectionOption) {
        if let audioGroup { player.currentItem?.select(option, in: audioGroup); audioSelection = option }
    }
    func loadSubtitles(_ url: URL, automatic: Bool = false) {
        guard sourceURL != nil, phase != .empty, phase != .failed else { return }
        subtitleTask?.cancel()
        let token = generation
        subtitleTask = Task {
            do {
                let doc = try await Task.detached(priority: .userInitiated) { try SubtitleDocument.read(url) }.value
                try Task.checkCancellation()
                guard generation == token else { return }
                if let subtitleGroup { player.currentItem?.select(nil, in: subtitleGroup) }
                subtitleSelection = nil
                externalSubtitles = doc; externalSubtitleName = url.lastPathComponent
                subtitleText = activeSubtitleText(at: position)
                if externalPlayback || isCompatibilityStreaming { prepareTV(at: position, play: wantsPlayback) }
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                let code = error as NSError
                if automatic, code.domain == NSCocoaErrorDomain,
                   [NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadNoPermissionError].contains(code.code) { return }
                issue = (error as? MediaIssue)?.localizedDescription ?? "The subtitle file cannot be read. Open it again to grant access."
            }
        }
    }
    func checkpoint() {
        if let entryID { library.update(entryID, position: position, duration: duration) }
        lastSavedPosition = position
    }
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) {
        guard subtitleAppearance != appearance else { return }
        subtitleAppearance = appearance; appearance.save()
        if isCompatibilityStreaming, burnSubtitlesForTV, externalSubtitles != nil { prepareTV(at: position, play: wantsPlayback) }
    }
    func setBurnSubtitlesForTV(_ enabled: Bool) {
        guard burnSubtitlesForTV != enabled else { return }
        burnSubtitlesForTV = enabled
        if isCompatibilityStreaming { prepareTV(at: position, play: wantsPlayback) }
    }
    func adjustSubtitleOffset(by delta: Double) {
        let clamped = max(-30.0, min(30.0, subtitleOffsetSeconds + delta))
        subtitleOffsetSeconds = (clamped * 100).rounded() / 100
        subtitleText = activeSubtitleText(at: position)
        if isCompatibilityStreaming, externalSubtitles != nil {
            prepareTV(at: position, play: wantsPlayback)
        }
    }
    func resetSubtitleOffset() {
        guard subtitleOffsetSeconds != 0 else { return }
        subtitleOffsetSeconds = 0
        subtitleText = activeSubtitleText(at: position)
        if isCompatibilityStreaming, externalSubtitles != nil {
            prepareTV(at: position, play: wantsPlayback)
        }
    }
    func applyDownloadedSubtitles(url: URL, document: SubtitleDocument) {
        if let subtitleGroup { player.currentItem?.select(nil, in: subtitleGroup) }
        subtitleSelection = nil
        externalSubtitles = document
        externalSubtitleName = url.lastPathComponent
        subtitleText = activeSubtitleText(at: position)
        if externalPlayback || isCompatibilityStreaming {
            prepareTV(at: position, play: wantsPlayback)
        }
    }
    static func matchingOption(in group: AVMediaSelectionGroup?, preferredLanguage: String) -> AVMediaSelectionOption? {
        let query = preferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let group, !query.isEmpty else { return nil }
        for option in group.options {
            if let tag = option.extendedLanguageTag?.lowercased(), (tag == query || tag.hasPrefix(query + "-")) { return option }
            if let code = option.locale?.language.languageCode?.identifier.lowercased(), code == query { return option }
            if option.displayName.lowercased().contains(query) { return option }
        }
        return nil
    }
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase != .playing else { return }
                self.togglePlayback()
            }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .playing else { return }
                self.togglePlayback()
            }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayback() }
            return .success
        }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor [weak self] in self?.skip(interval) }
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor [weak self] in self?.skip(-interval) }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playPrevious() }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = posEvent.positionTime
            Task { @MainActor [weak self] in self?.seek(to: target) }
            return .success
        }
    }
    func updateNowPlayingInfo() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = canPlayNext
        center.previousTrackCommand.isEnabled = canPlayPrevious
        guard phase != .empty, sourceURL != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? Double(playbackRate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let duration, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if queue.count > 1 {
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
        }
        if let artwork {
            let image = artwork
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = (phase == .playing) ? .playing : .paused
    }
    func setPreventSleepWhilePlaying(_ enabled: Bool) {
        guard preventSleepWhilePlaying != enabled else { return }
        preventSleepWhilePlaying = enabled
        UserDefaults.standard.set(enabled, forKey: "preventSleepWhilePlaying")
        updateSleepAssertion()
    }
    private func updateSleepAssertion() {
        let shouldPrevent = preventSleepWhilePlaying && (
            phase == .playing ||
            isPreparingForTV ||
            cast.activeDevice != nil ||
            (wantsPlayback && (phase == .loading || phase == .waiting || phase == .seeking || externalPlayback))
        )
        if shouldPrevent, !isPreventingSleep {
            var id = IOPMAssertionID(kIOPMNullAssertionID)
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "AirPlayr Media Playback" as CFString,
                &id
            )
            if status == kIOReturnSuccess {
                sleepAssertionID = id
                isPreventingSleep = true
            }
        } else if !shouldPrevent, isPreventingSleep {
            releaseSleepAssertion()
        }
    }
    private func releaseSleepAssertion() {
        if sleepAssertionID != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        }
        isPreventingSleep = false
    }
    func startCasting(to device: CastReceiverDevice) {
        guard sourceURL != nil else { return }
        if let url = stream?.url {
            cast.connect(device, streamURL: url, title: title, position: position)
            updateSleepAssertion()
        } else {
            prepareTV(at: position, play: true, castTarget: device)
        }
    }
    func stopCasting() {
        cast.disconnect()
        updateSleepAssertion()
    }
    func prepareForTV() { prepareTV(at: position, play: wantsPlayback) }

    /// A fresh stream starts at the requested source position; the UI retains the full movie timeline.
    private func prepareTV(at seconds: Double, play: Bool, castTarget: CastReceiverDevice? = nil) {
        guard let sourceURL else { return }
        streamTask?.cancel(); stream?.stop()
        generation = UUID(); seekGeneration = UUID()
        let token = generation
        if observations.count > 3 { observations.removeSubrange(3...) }
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        player.pause()
        position = seconds; wantsPlayback = play
        isPreparingForTV = true; isCompatibilityStreaming = true
        phase = .waiting; issue = nil; diagnosticCode = nil
        routeMessage = "Preparing a short TV playback buffer…"
        let session = AutomaticStreamSession(source: sourceURL, start: seconds, subtitles: externalSubtitles?.shifted(by: subtitleOffsetSeconds), appearance: subtitleAppearance, burnSubtitles: burnSubtitlesForTV)
        stream = session
        streamTask = Task { [weak self] in
            do {
                let url = try await session.prepare { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.streamFailed(message)
                    }
                }
                try Task.checkCancellation()
                guard let self, self.generation == token else { session.stop(); return }
                let item = AVPlayerItem(url: url)
                let legible = try await item.asset.loadMediaSelectionGroup(for: .legible)
                let audible = try await item.asset.loadMediaSelectionGroup(for: .audible)
                guard self.generation == token else { session.stop(); return }
                item.preferredForwardBufferDuration = 6
                self.player.automaticallyWaitsToMinimizeStalling = true
                self.streamStart = seconds
                self.player.replaceCurrentItem(with: item)
                self.isPreparingForTV = false
                self.phase = .ready
                self.routeMessage = MKVBridge.requiresBridge(sourceURL) ? "MKV prepared automatically • up to 4K/1080p · stereo audio" : "TV-compatible movie • seek with the TV remote or timeline"
                self.subtitleGroup = legible; self.audioGroup = audible
                let externalOption = self.externalSubtitles != nil && !self.burnSubtitlesForTV ? legible?.options.first(where: { $0.displayName == "External SRT" }) : nil
                let chosenSubtitle = externalOption ?? Self.matchingOption(in: legible, preferredLanguage: self.preferredSubtitleLanguage)
                if let legible { item.select(chosenSubtitle, in: legible) }
                self.subtitleSelection = chosenSubtitle
                if let audible {
                    if let preferredAud = Self.matchingOption(in: audible, preferredLanguage: self.preferredAudioLanguage) {
                        item.select(preferredAud, in: audible)
                        self.audioSelection = preferredAud
                    } else {
                        self.audioSelection = item.currentMediaSelection.selectedMediaOption(in: audible)
                    }
                } else {
                    self.audioSelection = nil
                }
                self.updateNowPlayingInfo()
                if !session.trackNotices.isEmpty { self.issue = session.trackNotices.joined(separator: " ") }
                if let target = castTarget ?? self.cast.activeDevice {
                    self.cast.connect(target, streamURL: url, title: self.title, position: seconds)
                    self.updateSleepAssertion()
                }
                self.installItemObservers(item, generation: token)
                // Start only after readiness; starting an HLS item before readiness can leave its clock at zero.

            } catch is CancellationError { session.stop() }
            catch {
                guard let self, self.generation == token else { session.stop(); return }
                self.streamFailed(error.localizedDescription)
            }
        }
    }
    private func streamFailed(_ message: String) {
        stream?.stop(); isPreparingForTV = false
        player.pause(); phase = .failed; issue = message
    }
    private func clearItem() {
        cast.disconnect()
        streamStart = nil; streamTask?.cancel(); streamTask = nil; stream?.stop(); stream = nil
        isPreparingForTV = false; isCompatibilityStreaming = false; wantsPlayback = false
        releaseSleepAssertion()
        player.automaticallyWaitsToMinimizeStalling = true
        player.pause(); player.replaceCurrentItem(with: nil)
        if observations.count > 3 { observations.removeSubrange(3...) }
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        scope = nil; subtitleFolderAccess = nil; entryID = nil; position = 0; duration = nil; lastSavedPosition = 0
        subtitleGroup = nil; audioGroup = nil; subtitleSelection = nil; audioSelection = nil
        externalSubtitles = nil; externalSubtitleName = nil; subtitleText = ""; dimensions = nil; artwork = nil
    }
    func stop() {
        checkpoint(); loadTask?.cancel(); subtitleTask?.cancel(); generation = UUID()
        clearItem(); phase = .empty; title = "AirPlayr"; issue = nil; diagnosticCode = nil; routeMessage = nil
    }
    func shutdown() {
        stop()
        cast.stopDiscovery()
        releaseSleepAssertion()
        observations.removeAll()
        if let periodic { player.removeTimeObserver(periodic); self.periodic = nil }
    }
    deinit {
        if sleepAssertionID != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(sleepAssertionID)
        }
        loadTask?.cancel(); subtitleTask?.cancel()
        notifications.forEach(NotificationCenter.default.removeObserver)
        if let periodic { player.removeTimeObserver(periodic) }
    }
}
