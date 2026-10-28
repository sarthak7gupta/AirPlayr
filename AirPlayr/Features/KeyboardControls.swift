import SwiftUI
import AppKit

/// Limit unmodified media shortcuts to the player window and never consume text editing.
struct KeyboardControls: NSViewRepresentable {
    let playback: PlaybackService
    let skipInterval: Double
    func makeCoordinator() -> Coordinator { Coordinator(playback: playback, skip: skipInterval) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.skip = skipInterval }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }
    @MainActor final class Coordinator {
        weak var view: NSView?
        let playback: PlaybackService
        var skip: Double
        private var monitor: Any?
        init(playback: PlaybackService, skip: Double) { self.playback = playback; self.skip = skip }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
        func handle(_ event: NSEvent) -> NSEvent? {
                guard let window = self.view?.window,
                      window.isKeyWindow || event.windowNumber == window.windowNumber,
                      window.attachedSheet == nil, !((window.firstResponder as? NSTextView)?.isEditable ?? false),
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                switch event.keyCode {
                case 49: self.playback.togglePlayback() // Space
                case 123: self.playback.skip(-self.skip)
                case 124: self.playback.skip(self.skip)
                case 125: self.playback.adjustVolume(-0.05)
                case 126: self.playback.adjustVolume(0.05)
                case 53:
                    guard window.styleMask.contains(.fullScreen) else { return event }
                    window.toggleFullScreen(nil)
                default:
                    guard event.charactersIgnoringModifiers?.lowercased() == "m" else { return event }
                    self.playback.toggleMute()
                }
                return nil
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
