import Foundation
import AVFoundation

/// Maps framework errors to short codes and user-facing guidance without leaking file paths.
///
/// Never include `NSError` descriptions or `userInfo` in diagnostics: they may contain file URLs.
enum PlaybackDiagnostics {
    static func code(_ error: Error?) -> String {
        guard let error else { return "No framework error code supplied" }
        var current: NSError? = error as NSError
        var parts: [String] = []
        let safeDomains = [AVFoundationErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain]
        for _ in 0..<4 {
            guard let value = current else { break }
            let domain = safeDomains.contains(value.domain) ? value.domain : "MediaFramework"
            parts.append("\(domain) \(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " → ")
    }
    static func guidance(_ error: Error?, external: Bool) -> String {
        if let error = error as NSError?, error.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: error.code) {
            case .decoderNotFound, .decodeFailed, .fileFormatNotRecognized, .fileFailedToParse:
                return "The media could not be decoded. Apple’s decoder cannot read this source. Try a different H.264/AAC MP4."
            case .externalPlaybackNotSupportedForAsset:
                return "This TV could not play the compatibility stream. Check Local Network permission, reconnect the TV, and retry."
            case .airPlayReceiverTemporarilyUnavailable:
                return "The AirPlay receiver is unavailable. Check the TV and network, select it again, then retry."
            default: break
            }
        }
        return external
            ? "The external video route connected, but playback failed. Select this Mac in the AirPlay menu to check local playback, or reconnect the TV and retry."
            : "Playback failed. Reopen the file to restore access, or try an H.264/AAC MP4."
    }
}
