import AVFoundation
import CoreImage
import CoreText

final class SubtitleVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: trackID)] }
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let subtitles: SubtitleDocument?
    let appearance: SubtitleAppearance
    init(trackID: CMPersistentTrackID, transform: CGAffineTransform, duration: CMTime, subtitles: SubtitleDocument?, appearance: SubtitleAppearance = SubtitleAppearance()) {
        self.trackID = trackID; self.transform = transform; self.subtitles = subtitles; self.appearance = appearance
        timeRange = CMTimeRange(start: .zero, duration: duration)
    }
}

/// Incremental streaming and offline export. Core Image renders source frames and Core Text captions into encoded pixels.
final class SubtitleVideoCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: Any]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    private let queue = DispatchQueue(label: "com.airplayr.subtitle-export", qos: .userInitiated)
    private let context = CIContext()
    private let lock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?
    private var generation = 0
    private let cache = NSCache<NSString, CIImage>()
    override init() { super.init(); cache.countLimit = 8 }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.lock(); renderContext = newRenderContext; lock.unlock()
    }
    func cancelAllPendingVideoCompositionRequests() { lock.lock(); generation += 1; lock.unlock() }
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock(); let token = generation; let render = renderContext; lock.unlock()
        queue.async { [self] in
            autoreleasepool {
                lock.lock(); let cancelled = token != generation; lock.unlock()
                if cancelled { request.finishCancelledRequest(); return }
                guard let instruction = request.videoCompositionInstruction as? SubtitleVideoInstruction,
                      let source = request.sourceFrame(byTrackID: instruction.trackID),
                      let output = render?.newPixelBuffer() else {
                    request.finish(with: ExportIssue("Could not render a video frame.")); return
                }
                let size = CGSize(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
                let bounds = CGRect(origin: .zero, size: size)
                var frame = CIImage(cvPixelBuffer: source).transformed(by: instruction.transform).cropped(to: bounds)
                let text = instruction.subtitles?.text(at: request.compositionTime.seconds) ?? ""
                if !text.isEmpty, let overlay = caption(text, size: size, style: instruction.appearance) { frame = overlay.composited(over: frame) }
                context.render(frame, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
                request.finish(withComposedVideoFrame: output)
            }
        }
    }
    private func caption(_ text: String, size: CGSize, style: SubtitleAppearance) -> CIImage? {
        let key = "\(size.width)x\(size.height):\(style):\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let drawing = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let fontSize = max(12, size.height * style.size.scale)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            let setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate([setting], 1)
        }
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1), NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph]
        if style.background == .outline {
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -3
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CGColor(gray: 0, alpha: 1)
        }
        let string = NSAttributedString(string: text, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(string)
        let width = size.width * style.width.fraction
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: width - 20, height: size.height * 0.45), nil)
        let fittedWidth = min(width, ceil(measured.width) + 20)
        let height = min(size.height * 0.45, ceil(measured.height) + 20)
        let y = style.position == .top ? size.height * (1 - style.position.margin) - height : size.height * style.position.margin
        let box = CGRect(x: (size.width - fittedWidth) / 2, y: y, width: fittedWidth, height: height)
        if style.background == .box {
            drawing.setFillColor(CGColor(gray: 0, alpha: 0.7))
            drawing.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil)); drawing.fillPath()
        }
        let path = CGPath(rect: box.insetBy(dx: 10, dy: 8), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), drawing)
        guard let image = drawing.makeImage() else { return nil }
        let result = CIImage(cgImage: image); cache.setObject(result, forKey: key)
        return result
    }
}
